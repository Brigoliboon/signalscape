import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import ColumnElement
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_builder
from app.api.pagination import (
    Page,
    PageParams,
    paginate,
    pagination_params,
    sort_param,
)
from app.db.session import get_db
from app.models.site import Site
from app.models.user import User, UserRole
from app.schemas.result import Thresholds
from app.schemas.site import (
    ConsolidationCreate,
    ConsolidationRead,
    SiteCreate,
    SiteDetail,
    SiteRead,
    SiteUpdate,
)
from app.services.consolidation import consolidate
from app.services.sites import (
    buildings_from_ids,
    get_site_or_404,
    visible_sites,
)

router = APIRouter(prefix="/api/sites", tags=["sites"])

site_sort = sort_param(
    {"name": Site.name, "created_at": Site.created_at},
    default="name",
    tie_breaker=Site.id,
)


def _escape_like(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _name_taken() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_409_CONFLICT,
        detail="You already have a site with this name",
    )


@router.get("", response_model=Page[SiteRead])
def list_sites(
    q: str | None = Query(None, description="Search name or description"),
    owner_id: Annotated[uuid.UUID | None, Query(description="Admin only")] = None,
    page: PageParams = Depends(pagination_params),
    order_by: list[ColumnElement] = Depends(site_sort),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    if owner_id is not None and user.role != UserRole.ADMIN:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only admins can filter by owner",
        )
    stmt = visible_sites(user)
    if owner_id is not None:
        stmt = stmt.where(Site.owner_id == owner_id)
    if q and q.strip():
        pattern = f"%{_escape_like(q.strip())}%"
        stmt = stmt.where(
            Site.name.ilike(pattern, escape="\\")
            | Site.description.ilike(pattern, escape="\\")
        )
    return paginate(db, stmt, page, order_by)


@router.post("", response_model=SiteRead, status_code=status.HTTP_201_CREATED)
def create_site(
    payload: SiteCreate,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> Site:
    data = payload.model_dump(exclude={"building_ids", "outdoor_area"})
    outdoor = payload.outdoor_area
    site = Site(
        owner_id=user.id,
        **data,
        outdoor_area=[point.model_dump() for point in outdoor] if outdoor else None,
    )
    site.buildings = buildings_from_ids(db, user, payload.building_ids)
    db.add(site)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise _name_taken() from None
    db.refresh(site)
    return site


@router.get("/{site_id}", response_model=SiteDetail)
def get_site(
    site_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Site:
    return get_site_or_404(db, user, site_id)


@router.patch("/{site_id}", response_model=SiteRead)
def update_site(
    site_id: uuid.UUID,
    payload: SiteUpdate,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> Site:
    site = get_site_or_404(db, user, site_id)
    data = payload.model_dump(exclude_unset=True, exclude={"building_ids"})
    if "outdoor_area" in data and data["outdoor_area"] is not None:
        data["outdoor_area"] = [point.model_dump() for point in payload.outdoor_area]
    for field, value in data.items():
        setattr(site, field, value)
    if payload.building_ids is not None:
        site.buildings = buildings_from_ids(db, user, payload.building_ids)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise _name_taken() from None
    db.refresh(site)
    return site


@router.delete("/{site_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_site(
    site_id: uuid.UUID,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> None:
    site = get_site_or_404(db, user, site_id)
    db.delete(site)
    db.commit()


@router.post("/{site_id}/consolidate", response_model=ConsolidationRead)
def consolidate_site(
    site_id: uuid.UUID,
    payload: ConsolidationCreate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ConsolidationRead:
    """Merge the selected surveys onto one coverage map, with their access
    points and the dead and weak layer (FR-34). Nothing is stored."""
    site = get_site_or_404(db, user, site_id)
    thresholds = Thresholds(
        good_dbm=user.good_threshold_dbm, dead_dbm=user.dead_threshold_dbm
    )
    return consolidate(db, site, payload.survey_ids, user, thresholds)
