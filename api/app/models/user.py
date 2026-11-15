import enum
import uuid
from datetime import datetime

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    Enum,
    Index,
    SmallInteger,
    Text,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class UserRole(enum.StrEnum):
    ADMIN = "admin"
    SURVEYOR = "surveyor"
    VIEWER = "viewer"


DEFAULT_GOOD_THRESHOLD_DBM = -67
DEFAULT_DEAD_THRESHOLD_DBM = -80


class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        CheckConstraint(
            "dead_threshold_dbm < good_threshold_dbm", name="ck_users_dead_lt_good"
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        server_default=text("gen_random_uuid()"),
    )
    email: Mapped[str] = mapped_column(Text, nullable=False)
    name: Mapped[str] = mapped_column(Text, nullable=False)
    password_hash: Mapped[str] = mapped_column(Text, nullable=False)
    role: Mapped[UserRole] = mapped_column(
        Enum(
            UserRole,
            name="user_role",
            values_callable=lambda enum_cls: [member.value for member in enum_cls],
        ),
        nullable=False,
        default=UserRole.SURVEYOR,
        server_default=UserRole.SURVEYOR.value,
    )
    is_active: Mapped[bool] = mapped_column(
        nullable=False, default=True, server_default=text("true")
    )
    consented_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    good_threshold_dbm: Mapped[int] = mapped_column(
        SmallInteger,
        nullable=False,
        default=DEFAULT_GOOD_THRESHOLD_DBM,
        server_default=text(str(DEFAULT_GOOD_THRESHOLD_DBM)),
    )
    dead_threshold_dbm: Mapped[int] = mapped_column(
        SmallInteger,
        nullable=False,
        default=DEFAULT_DEAD_THRESHOLD_DBM,
        server_default=text(str(DEFAULT_DEAD_THRESHOLD_DBM)),
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


# Emails are unique regardless of case. The API also stores them lowercased.
Index("uq_users_email_lower", func.lower(User.email), unique=True)
