import uuid
from datetime import datetime
from typing import Self

from pydantic import (
    BaseModel,
    ConfigDict,
    EmailStr,
    Field,
    field_validator,
    model_validator,
)

from app.core.security import MAX_PASSWORD_BYTES
from app.models.user import UserRole

# Valid RSSI range, matching the scan_readings check in the design.
MIN_DBM = -120
MAX_DBM = 0


def _check_password(value: str) -> str:
    if len(value.encode("utf-8")) > MAX_PASSWORD_BYTES:
        raise ValueError(f"password must be at most {MAX_PASSWORD_BYTES} bytes")
    return value


class UserRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: str
    name: str
    role: UserRole
    is_active: bool
    consented_at: datetime | None
    good_threshold_dbm: int
    dead_threshold_dbm: int
    created_at: datetime
    updated_at: datetime


class UserCreate(BaseModel):
    email: EmailStr
    name: str = Field(min_length=1, max_length=100)
    password: str = Field(min_length=8)

    @field_validator("name")
    @classmethod
    def strip_name(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("name must not be blank")
        return value

    _password_length = field_validator("password")(_check_password)


class ProfileUpdate(BaseModel):
    """PATCH /auth/me. Only the fields that are sent are changed."""

    name: str | None = Field(default=None, min_length=1, max_length=100)
    password: str | None = Field(default=None, min_length=8)
    current_password: str | None = None
    good_threshold_dbm: int | None = Field(default=None, ge=MIN_DBM, le=MAX_DBM)
    dead_threshold_dbm: int | None = Field(default=None, ge=MIN_DBM, le=MAX_DBM)

    @model_validator(mode="after")
    def check_fields(self) -> Self:
        for field in self.model_fields_set:
            if getattr(self, field) is None:
                raise ValueError(f"{field} must not be null")
        if self.password is not None:
            _check_password(self.password)
            if self.current_password is None:
                raise ValueError("current_password is required to change the password")
        if self.name is not None:
            self.name = self.name.strip()
            if not self.name:
                raise ValueError("name must not be blank")
        if (
            self.good_threshold_dbm is not None
            and self.dead_threshold_dbm is not None
            and self.dead_threshold_dbm >= self.good_threshold_dbm
        ):
            raise ValueError("dead_threshold_dbm must be lower than good_threshold_dbm")
        return self


class UserAdminUpdate(BaseModel):
    """PATCH /users/{id}. Admin only."""

    role: UserRole | None = None
    is_active: bool | None = None

    @model_validator(mode="after")
    def no_nulls(self) -> Self:
        for field in self.model_fields_set:
            if getattr(self, field) is None:
                raise ValueError(f"{field} must not be null")
        return self


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
