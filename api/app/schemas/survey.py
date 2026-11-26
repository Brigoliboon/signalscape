import re
import uuid
from datetime import datetime
from typing import Annotated, Self

from pydantic import (
    AfterValidator,
    AwareDatetime,
    BaseModel,
    ConfigDict,
    EmailStr,
    Field,
    field_validator,
    model_validator,
)

from app.models.survey import (
    MAX_ORIGIN_ACCURACY_M,
    CheckpointSource,
    SurveyStatus,
)

# Batch limits (DESIGN.md section 4). The app sends up to 500 at a time.
MAX_READING_BATCH = 1000
MAX_CHECKPOINT_BATCH = 1000

MIN_DBM = -120
MAX_DBM = 0
MAX_SSID_BYTES = 32

_MAC_RE = re.compile(r"^[0-9a-f]{2}([:-])(?:[0-9a-f]{2}\1){4}[0-9a-f]{2}$")

Latitude = Annotated[float, Field(ge=-90, le=90)]
Longitude = Annotated[float, Field(ge=-180, le=180)]


def normalize_bssid(value: str) -> str:
    """Return a BSSID as lower-case ``aa:bb:cc:dd:ee:ff``. Accepts ``-`` too."""
    value = value.strip().lower()
    if not _MAC_RE.match(value):
        raise ValueError("must be a MAC address like aa:bb:cc:dd:ee:ff")
    return value.replace("-", ":")


Bssid = Annotated[str, AfterValidator(normalize_bssid)]


# --- surveys ----------------------------------------------------------------


class SurveyCreate(BaseModel):
    """POST /surveys. The survey starts as ``active`` at the time of the request."""

    building_id: uuid.UUID
    device_model: str | None = Field(default=None, max_length=200)
    has_barometer: bool = False
    origin_lat: Latitude
    origin_lng: Longitude
    origin_accuracy_m: float = Field(
        ge=0,
        le=MAX_ORIGIN_ACCURACY_M,
        description=f"GPS accuracy of the start fix; at most {MAX_ORIGIN_ACCURACY_M} m",
    )
    step_length_m: float = Field(default=0.7, gt=0, lt=10)
    notes: str | None = Field(default=None, max_length=2000)

    @field_validator("device_model", "notes")
    @classmethod
    def strip_optional(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return value.strip() or None


class SurveyUpdate(BaseModel):
    """PATCH /surveys/{id}. Only the fields that are sent are changed.

    ``processed`` is set by processing, so it cannot be requested here.
    """

    status: SurveyStatus | None = None
    notes: str | None = Field(default=None, max_length=2000)

    @field_validator("status")
    @classmethod
    def not_processed(cls, value: SurveyStatus | None) -> SurveyStatus | None:
        if value == SurveyStatus.PROCESSED:
            raise ValueError("status can only be active, paused or completed")
        return value

    @field_validator("notes")
    @classmethod
    def strip_notes(cls, value: str | None) -> str | None:
        return None if value is None else value.strip() or None

    @model_validator(mode="after")
    def status_not_null(self) -> Self:
        if "status" in self.model_fields_set and self.status is None:
            raise ValueError("status must not be null")
        return self


class SurveyRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    building_id: uuid.UUID
    surveyor_id: uuid.UUID
    surveyor_name: str
    status: SurveyStatus
    started_at: datetime
    ended_at: datetime | None
    device_model: str | None
    has_barometer: bool
    origin_lat: float
    origin_lng: float
    origin_accuracy_m: float
    step_length_m: float
    notes: str | None
    processed_at: datetime | None
    created_at: datetime
    updated_at: datetime


# --- readings ---------------------------------------------------------------


class ReadingIn(BaseModel):
    client_id: uuid.UUID
    floor_id: uuid.UUID
    lat: Latitude
    lng: Longitude
    accuracy_m: float | None = Field(default=None, ge=0, lt=1000)
    bssid: Bssid
    ssid: str = Field(default="", description="Empty for hidden networks")
    rssi_dbm: int = Field(ge=MIN_DBM, le=MAX_DBM)
    frequency_mhz: int = Field(ge=2400, le=7200)
    scanned_at: AwareDatetime

    @field_validator("ssid")
    @classmethod
    def ssid_length(cls, value: str) -> str:
        if len(value.encode("utf-8")) > MAX_SSID_BYTES:
            raise ValueError(f"ssid must be at most {MAX_SSID_BYTES} bytes")
        if "\x00" in value:
            raise ValueError("ssid must not contain NUL characters")
        return value


class ReadingBatch(BaseModel):
    readings: list[ReadingIn] = Field(min_length=1, max_length=MAX_READING_BATCH)


class ReadingRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    survey_id: uuid.UUID
    floor_id: uuid.UUID
    client_id: uuid.UUID
    lat: float
    lng: float
    accuracy_m: float | None
    bssid: str
    ssid: str
    rssi_dbm: int
    frequency_mhz: int
    scanned_at: datetime


class BatchResult(BaseModel):
    """Counts for an idempotent batch upload. Skipped rows were already stored."""

    inserted: int
    skipped: int


# --- checkpoints ------------------------------------------------------------


class CheckpointIn(BaseModel):
    client_id: uuid.UUID
    floor_id: uuid.UUID
    lat: Latitude
    lng: Longitude
    estimated_lat: Latitude
    estimated_lng: Longitude
    source: CheckpointSource
    recorded_at: AwareDatetime


class CheckpointBatch(BaseModel):
    checkpoints: list[CheckpointIn] = Field(
        min_length=1, max_length=MAX_CHECKPOINT_BATCH
    )


class CheckpointRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    survey_id: uuid.UUID
    floor_id: uuid.UUID
    client_id: uuid.UUID
    lat: float
    lng: float
    estimated_lat: float
    estimated_lng: float
    source: CheckpointSource
    recorded_at: datetime
    created_at: datetime


# --- shares -----------------------------------------------------------------


class ShareCreate(BaseModel):
    email: EmailStr


class ShareRead(BaseModel):
    survey_id: uuid.UUID
    user_id: uuid.UUID
    email: str
    name: str
    created_at: datetime
