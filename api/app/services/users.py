from fastapi import HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models.user import User, UserRole


def ensure_not_last_admin(db: Session, user: User, action: str) -> None:
    """Refuse an action that would leave the system without an active admin."""
    if user.role != UserRole.ADMIN or not user.is_active:
        return
    other_admins = db.scalar(
        select(func.count())
        .select_from(User)
        .where(
            User.role == UserRole.ADMIN,
            User.is_active.is_(True),
            User.id != user.id,
        )
    )
    if not other_admins:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Cannot {action} the last active admin",
        )
