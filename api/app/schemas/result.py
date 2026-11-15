import uuid
from datetime import datetime
from typing import Literal

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


class TrailPoint(BaseModel):
    """One place on the walk. ``kind`` is ``start`` (the survey origin),
    ``reading`` (a Wi-Fi scan) or ``checkpoint``."""

    floor_id: uuid.UUID
    floor_level: int
    lat: float
    lng: float
    at: datetime
    kind: Literal["start", "reading", "checkpoint"]


class TrailFloor(BaseModel):
    floor_id: uuid.UUID
    floor_level: int
    points: list[TrailPoint]


class TrailRead(BaseModel):
    """The walk of a survey, in time order, with the start and the last place.

    Only scan positions and checkpoints are uploaded, so the line is as fine as
    the scans were. ``start`` is the survey origin placed on the floor of the
    first point; ``end`` is the last scan or checkpoint. Both are ``null`` when
    nothing has been uploaded yet.
    """

    survey_id: uuid.UUID
    start: TrailPoint | None
    end: TrailPoint | None
    floors: list[TrailFloor]
