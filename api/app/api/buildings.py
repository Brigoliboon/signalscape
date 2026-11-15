import uuid
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import ColumnElement, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_uploads_dir, require_builder
from app.api.pagination import (
    Page,
    PageParams,
    paginate,
    pagination_params,
    sort_param,
)
from app.db.session import get_db
from app.models.building import Building, Floor
from app.models.user import User, UserRole
from app.schemas.building import (
    BuildingCreate,
    BuildingDetail,
    BuildingRead,
    BuildingUpdate,
    FloorCreate,
    FloorRead,
)
from app.services.buildings import (
    delete_plan_files,
    get_building_or_404,
    plan_files_for_buildings,
    visible_buildings,
)

router = APIRouter(prefix="/api/buildings", tags=["buildings"])

building_sort = sort_param(
    {"name": Building.name, "created_at": Building.created_at},
    default="name",
    tie_breaker=Building.id,
)
floor_sort = sort_param({"level": Floor.level}, default="level", tie_breaker=Floor.id)


def _escape_like(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _name_taken() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_409_CONFLICT,
        detail="You already have a building with this name",
    )


def _level_taken() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_409_CONFLICT,
        detail="This building already has a floor at that level",
    )


@router.get("", response_model=Page[BuildingRead])
def list_buildings(
    q: str | None = Query(None, description="Search name or address"),
    owner_id: Annotated[uuid.UUID | None, Query(description="Admin only")] = None,
    page: PageParams = Depends(pagination_params),
    order_by: list[ColumnElement] = Depends(building_sort),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    if owner_id is not None and user.role != UserRole.ADMIN:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only admins can filter by owner",
        )
    stmt = visible_buildings(user)
    if owner_id is not None:
        stmt = stmt.where(Building.owner_id == owner_id)
    if q and q.strip():
        pattern = f"%{_escape_like(q.strip())}%"
        stmt = stmt.where(
            Building.name.ilike(pattern, escape="\\")
            | Building.address.ilike(pattern, escape="\\")
        )
    return paginate(db, stmt, page, order_by)


@router.post("", response_model=BuildingRead, status_code=status.HTTP_201_CREATED)
def create_building(
    payload: BuildingCreate,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> Building:
    building = Building(owner_id=user.id, **payload.model_dump())
    db.add(building)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise _name_taken() from None
    db.refresh(building)
    return building


@router.get("/{building_id}", response_model=BuildingDetail)
def get_building(
    building_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Building:
    return get_building_or_404(db, user, building_id)


@router.patch("/{building_id}", response_model=BuildingRead)
def update_building(
    building_id: uuid.UUID,
    payload: BuildingUpdate,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> Building:
    building = get_building_or_404(db, user, building_id)
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(building, field, value)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise _name_taken() from None
    db.refresh(building)
    return building


@router.delete("/{building_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_building(
    building_id: uuid.UUID,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
    uploads_dir: Path = Depends(get_uploads_dir),
) -> Response:
    building = get_building_or_404(db, user, building_id)
    plan_files = plan_files_for_buildings(db, [building.id])
    db.delete(building)
    db.commit()
    delete_plan_files(uploads_dir, plan_files)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/{building_id}/floors", response_model=Page[FloorRead])
def list_floors(
    building_id: uuid.UUID,
    page: PageParams = Depends(pagination_params),
    order_by: list[ColumnElement] = Depends(floor_sort),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    building = get_building_or_404(db, user, building_id)
    stmt = select(Floor).where(Floor.building_id == building.id)
    return paginate(db, stmt, page, order_by)


@router.post(
    "/{building_id}/floors",
    response_model=FloorRead,
    status_code=status.HTTP_201_CREATED,
)
def create_floor(
    building_id: uuid.UUID,
    payload: FloorCreate,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> Floor:
    building = get_building_or_404(db, user, building_id)
    floor = Floor(building_id=building.id, **payload.model_dump())
    db.add(floor)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise _level_taken() from None
    db.refresh(floor)
    return floor
