import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import ColumnElement, or_, select
from sqlalchemy.orm import Session

from app.api.deps import get_uploads_dir, require_admin
from app.api.pagination import (
    Page,
    PageParams,
    paginate,
    pagination_params,
    sort_param,
)
from app.db.session import get_db
from app.models.user import User, UserRole
from app.schemas.user import UserAdminUpdate, UserRead
from app.services.buildings import delete_plan_files, plan_files_for_owner
from app.services.users import ensure_not_last_admin

router = APIRouter(
    prefix="/api/users", tags=["users"], dependencies=[Depends(require_admin)]
)

user_sort = sort_param(
    {"created_at": User.created_at, "name": User.name, "email": User.email},
    default="-created_at",
    tie_breaker=User.id,
)


def _escape_like(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _get_or_404(db: Session, user_id: uuid.UUID) -> User:
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not found")
    return user


@router.get("", response_model=Page[UserRead])
def list_users(
    role: UserRole | None = None,
    is_active: bool | None = None,
    q: str | None = Query(None, description="Search name or email"),
    page: PageParams = Depends(pagination_params),
    order_by: list[ColumnElement] = Depends(user_sort),
    db: Session = Depends(get_db),
) -> dict:
    stmt = select(User)
    if role is not None:
        stmt = stmt.where(User.role == role)
    if is_active is not None:
        stmt = stmt.where(User.is_active.is_(is_active))
    if q:
        pattern = f"%{_escape_like(q.strip())}%"
        stmt = stmt.where(
            or_(
                User.name.ilike(pattern, escape="\\"),
                User.email.ilike(pattern, escape="\\"),
            )
        )
    return paginate(db, stmt, page, order_by)


@router.get("/{user_id}", response_model=UserRead)
def get_user(user_id: uuid.UUID, db: Session = Depends(get_db)) -> User:
    return _get_or_404(db, user_id)


@router.patch("/{user_id}", response_model=UserRead)
def update_user(
    user_id: uuid.UUID, payload: UserAdminUpdate, db: Session = Depends(get_db)
) -> User:
    user = _get_or_404(db, user_id)
    changes = payload.model_dump(exclude_unset=True)
    demoting = "role" in changes and changes["role"] != UserRole.ADMIN
    deactivating = changes.get("is_active") is False
    if demoting or deactivating:
        ensure_not_last_admin(db, user, "demote or deactivate")
    for field, value in changes.items():
        setattr(user, field, value)
    db.commit()
    db.refresh(user)
    return user


@router.delete("/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_user(
    user_id: uuid.UUID,
    db: Session = Depends(get_db),
    uploads_dir: Path = Depends(get_uploads_dir),
) -> Response:
    user = _get_or_404(db, user_id)
    ensure_not_last_admin(db, user, "delete")
    plan_files = plan_files_for_owner(db, user.id)
    db.delete(user)
    db.commit()
    delete_plan_files(uploads_dir, plan_files)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
