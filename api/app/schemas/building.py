import uuid
from datetime import datetime
from typing import Self

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    computed_field,
    field_validator,
    model_validator,
)

MIN_LEVEL = -20
MAX_LEVEL = 200


def _strip_required(value: str) -> str:
    value = value.strip()
    if not value:
        raise ValueError("must not be blank")
    return value


def _strip_optional(value: str | None) -> str | None:
    if value is None:
        return None
    return value.strip() or None


class BuildingCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    address: str | None = Field(default=None, max_length=500)
    description: str | None = Field(default=None, max_length=2000)

    _strip_name = field_validator("name")(_strip_required)
    _strip_text = field_validator("address", "description")(_strip_optional)


class BuildingUpdate(BaseModel):
    """PATCH /buildings/{id}. Only the fields that are sent are changed."""

    name: str | None = Field(default=None, min_length=1, max_length=200)
    address: str | None = Field(default=None, max_length=500)
    description: str | None = Field(default=None, max_length=2000)

    @field_validator("name")
    @classmethod
    def strip_name(cls, value: str | None) -> str | None:
        return None if value is None else _strip_required(value)

    _strip_text = field_validator("address", "description")(_strip_optional)

    @model_validator(mode="after")
    def name_not_null(self) -> Self:
        if "name" in self.model_fields_set and self.name is None:
            raise ValueError("name must not be null")
        return self


class FloorCreate(BaseModel):
    level: int = Field(
        ge=MIN_LEVEL, le=MAX_LEVEL, description="0 = ground, negative = basement"
    )
    label: str = Field(min_length=1, max_length=50)
    # Optional. Only used to size the floor in the 3D view.
    width_m: float | None = Field(default=None, gt=0, lt=10000)
    length_m: float | None = Field(default=None, gt=0, lt=10000)
    height_m: float = Field(default=3.0, gt=0, lt=100)

    _strip_label = field_validator("label")(_strip_required)


class FloorUpdate(BaseModel):
    """PATCH /floors/{id}. Only the fields that are sent are changed."""

    level: int | None = Field(default=None, ge=MIN_LEVEL, le=MAX_LEVEL)
    label: str | None = Field(default=None, min_length=1, max_length=50)
    width_m: float | None = Field(default=None, gt=0, lt=10000)
    length_m: float | None = Field(default=None, gt=0, lt=10000)
    height_m: float | None = Field(default=None, gt=0, lt=100)

    @field_validator("label")
    @classmethod
    def strip_label(cls, value: str | None) -> str | None:
        return None if value is None else _strip_required(value)

    @model_validator(mode="after")
    def required_fields_not_null(self) -> Self:
        for field in ("level", "label", "height_m"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} must not be null")
        return self


class FloorRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    building_id: uuid.UUID
    level: int
    label: str
    width_m: float | None
    length_m: float | None
    height_m: float
    plan_image_path: str | None = Field(default=None, exclude=True)
    created_at: datetime
    updated_at: datetime

    @computed_field  # type: ignore[prop-decorator]
    @property
    def plan_url(self) -> str | None:
        if self.plan_image_path is None:
            return None
        return f"/api/floors/{self.id}/plan"


class BuildingRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    owner_id: uuid.UUID
    name: str
    address: str | None
    description: str | None
    created_at: datetime
    updated_at: datetime


class BuildingDetail(BuildingRead):
    floors: list[FloorRead]
