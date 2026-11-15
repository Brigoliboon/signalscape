from datetime import UTC, datetime
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Response, status
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_uploads_dir
from app.core.security import create_access_token, hash_password, verify_password
from app.db.session import get_db
from app.models.user import User, UserRole
from app.schemas.user import ProfileUpdate, TokenResponse, UserCreate, UserRead
from app.services.buildings import delete_plan_files, plan_files_for_owner
from app.services.users import ensure_not_last_admin

router = APIRouter(prefix="/api/auth", tags=["auth"])

# Checked when the email is unknown, so login takes about the same time either way.
_DUMMY_HASH = hash_password("not-a-real-password")


def _email_taken(db: Session, email: str) -> bool:
    return (
        db.scalar(select(User.id).where(func.lower(User.email) == email.lower()))
        is not None
    )


@router.post("/register", response_model=UserRead, status_code=status.HTTP_201_CREATED)
def register(payload: UserCreate, db: Session = Depends(get_db)) -> User:
    """Create a Surveyor account."""
    email = payload.email.lower()
    conflict = HTTPException(
        status_code=status.HTTP_409_CONFLICT, detail="Email is already registered"
    )
    if _email_taken(db, email):
        raise conflict
    user = User(
        email=email,
        name=payload.name,
        password_hash=hash_password(payload.password),
        role=UserRole.SURVEYOR,
    )
    db.add(user)
    try:
        db.commit()
    except IntegrityError:  # pragma: no cover - lost a race with another signup
        db.rollback()
        raise conflict from None
    db.refresh(user)
    return user


@router.post("/login", response_model=TokenResponse)
def login(
    form: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)
) -> TokenResponse:
    """Sign in with email (the form's ``username`` field) and password."""
    user = db.scalar(
        select(User).where(func.lower(User.email) == form.username.strip().lower())
    )
    password_ok = verify_password(
        form.password, user.password_hash if user else _DUMMY_HASH
    )
    if user is None or not password_ok or not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    token, expires_in = create_access_token(str(user.id), user.role.value)
    return TokenResponse(access_token=token, expires_in=expires_in)


@router.get("/me", response_model=UserRead)
def read_me(user: User = Depends(get_current_user)) -> User:
    return user


@router.patch("/me", response_model=UserRead)
def update_me(
    payload: ProfileUpdate,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> User:
    """Change your name, password (needs ``current_password``) or thresholds."""
    changes = payload.model_dump(exclude_unset=True)

    good = changes.get("good_threshold_dbm", user.good_threshold_dbm)
    dead = changes.get("dead_threshold_dbm", user.dead_threshold_dbm)
    if dead >= good:
        raise HTTPException(
            status_code=422,
            detail="dead_threshold_dbm must be lower than good_threshold_dbm",
        )

    if "password" in changes:
        if not verify_password(changes["current_password"], user.password_hash):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Current password is incorrect",
            )
        user.password_hash = hash_password(changes["password"])
    for field in ("name", "good_threshold_dbm", "dead_threshold_dbm"):
        if field in changes:
            setattr(user, field, changes[field])

    db.commit()
    db.refresh(user)
    return user


@router.post("/me/consent", response_model=UserRead)
def give_consent(
    user: User = Depends(get_current_user), db: Session = Depends(get_db)
) -> User:
    """Record privacy consent (FR-22). Repeating it keeps the first timestamp."""
    if user.consented_at is None:
        user.consented_at = datetime.now(UTC)
        db.commit()
        db.refresh(user)
    return user


@router.delete("/me", status_code=status.HTTP_204_NO_CONTENT)
def delete_me(
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    uploads_dir: Path = Depends(get_uploads_dir),
) -> Response:
    """Delete your account and, through cascades, all of its data (FR-20)."""
    ensure_not_last_admin(db, user, "delete")
    plan_files = plan_files_for_owner(db, user.id)
    db.delete(user)
    db.commit()
    delete_plan_files(uploads_dir, plan_files)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
