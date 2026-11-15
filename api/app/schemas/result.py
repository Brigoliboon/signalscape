import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict


class Thresholds(BaseModel):
    good_dbm: int
    dead_dbm: int


class AccessPointOut(BaseModel):
    floor_id: uuid.UUID
    floor_level: int
    bssid: str
    ssid: str
    frequency_mhz: int
    lat: float
    lng: float
    method: str
    reading_count: int
    max_rssi_dbm: int


class AccessPointRead(AccessPointOut):
    id: uuid.UUID
    survey_id: uuid.UUID
    computed_at: datetime


class CoverageRead(BaseModel):
    """One coverage grid. ``values`` is row-major, south row first, west column
    first; ``null`` means no data. ``origin_lat`` and ``origin_lng`` are the
    south-west corner."""

    survey_id: uuid.UUID
    floor_id: uuid.UUID
    floor_level: int
    bssid: str | None
    method: str
    cell_size_m: float
    origin_lat: float
    origin_lng: float
    cols: int
    rows: int
    values: list[float | None]
    good_pct: float
    fair_pct: float
    dead_pct: float
    thresholds: Thresholds
    raw_reading_count: int
    cleaned_reading_count: int
    computed_at: datetime


class FloorSummary(BaseModel):
    floor_id: uuid.UUID
    floor_level: int
    floor_label: str
    floor_height_m: float
    raw_reading_count: int
    cleaned_reading_count: int
    area_covered_m2: float
    good_pct: float
    fair_pct: float
    dead_pct: float
    thresholds: Thresholds | None
    access_point_count: int


class SurveySummary(BaseModel):
    survey_id: uuid.UUID
    status: str
    processed_at: datetime | None
    floors: list[FloorSummary]


class ProcessResult(BaseModel):
    """Result of ``POST /surveys/{id}/process``.

    A preview also carries the strongest-signal ``grids`` so the app can draw the
    live heatmap; a full run stores them and they are read from ``/coverage``.
    """

    survey_id: uuid.UUID
    status: str
    preview: bool
    computed_at: datetime
    thresholds: Thresholds
    floors: list[FloorSummary]
    access_points: list[AccessPointOut]
    grids: list[CoverageRead]


class NetworkRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    ssid: str
    bssid: str
    reading_count: int
    max_rssi_dbm: int
