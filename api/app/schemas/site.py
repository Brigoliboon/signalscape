import uuid
from datetime import datetime
from typing import Self

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    field_validator,
    model_validator,
)

from app.schemas.building import BuildingRead
from app.schemas.result import AccessPointOut, FloorSummary, Thresholds


class OutdoorPoint(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


def _strip_required(value: str) -> str:
    value = value.strip()
    if not value:
        raise ValueError("must not be blank")
    return value


def _strip_optional(value: str | None) -> str | None:
    if value is None:
        return None
    return value.strip() or None


def _validate_area(value: list[OutdoorPoint] | None) -> list[OutdoorPoint] | None:
    if value is None:
        return None
    if len(value) < 3:
        raise ValueError("outdoor_area needs at least 3 points")
    if len({(p.lat, p.lng) for p in value}) != len(value):
        raise ValueError("outdoor_area has duplicate points")
    return value


class SiteCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=2000)
    building_ids: list[uuid.UUID] = Field(default_factory=list)
    outdoor_area: list[OutdoorPoint] | None = None

    _strip_name = field_validator("name")(_strip_required)
    _strip_text = field_validator("description")(_strip_optional)
    _check_area = field_validator("outdoor_area")(_validate_area)


class SiteUpdate(BaseModel):
    """PATCH /sites/{id}. Only the fields that are sent are changed."""

    name: str | None = Field(default=None, min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=2000)
    building_ids: list[uuid.UUID] | None = None
    outdoor_area: list[OutdoorPoint] | None = None

    @field_validator("name")
    @classmethod
    def strip_name(cls, value: str | None) -> str | None:
        return None if value is None else _strip_required(value)

    _strip_text = field_validator("description")(_strip_optional)
    _check_area = field_validator("outdoor_area")(_validate_area)

    @model_validator(mode="after")
    def name_not_null(self) -> Self:
        if "name" in self.model_fields_set and self.name is None:
            raise ValueError("name must not be null")
        return self


class SiteRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    owner_id: uuid.UUID
    name: str
    description: str | None
    building_ids: list[uuid.UUID] = Field(default_factory=list)
    outdoor_area: list[OutdoorPoint] | None
    created_at: datetime
    updated_at: datetime


class SiteDetail(SiteRead):
    buildings: list[BuildingRead]


class ConsolidationCreate(BaseModel):
    """Surveys to merge onto one campus map (FR-34)."""

    survey_ids: list[uuid.UUID] = Field(min_length=1, max_length=100)

    @field_validator("survey_ids")
    @classmethod
    def unique_ids(cls, value: list[uuid.UUID]) -> list[uuid.UUID]:
        if len(set(value)) != len(value):
            raise ValueError("survey_ids must be unique")
        return value


class ConsolidatedGrid(BaseModel):
    """An IDW grid built from the selected surveys' combined readings.

    Same row-major layout as ``CoverageRead``; ``survey_id`` there is the site
    because these grids are not stored on any one survey.
    """

    floor_id: uuid.UUID
    floor_level: int
    floor_label: str
    bssid: str | None
    method: str
    cell_size_m: float
    origin_lat: float
    origin_lng: float
    cols: int
    rows: int
    values: list[float | None]
    confidence: list[float | None]
    good_pct: float
    fair_pct: float
    dead_pct: float
    thresholds: Thresholds
    raw_reading_count: int
    cleaned_reading_count: int


class ConsolidationRead(BaseModel):
    site_id: uuid.UUID
    survey_ids: list[uuid.UUID]
    computed_at: datetime
    thresholds: Thresholds
    floors: list[FloorSummary]
    grids: list[ConsolidatedGrid]
    access_points: list[AccessPointOut]
