import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict


class Thresholds(BaseModel):
    good_dbm: int
    dead_dbm: int


class AccessPointOut(BaseModel):
    """``method`` is ``path_loss_lsq`` (v1.1 fit) or ``weighted_centroid`` (too
    few readings to fit, or results from v1.0). ``confidence`` is 0 to 1;
    ``low_confidence`` is true below 5 readings or 3 m of spread (FR-24).
    ``spread_m`` is 2 x the RMS distance of the readings from their mean. All
    three are null on results processed before v1.1.

    ``position_determined`` is true only when at least one reading is in the
    good/strong band (at or above the survey's FR-15 ``good_dbm``, default
    -67 dBm). Until then ``lat`` and ``lng`` are null: the estimated
    coordinates are not returned, so clients do not plot a guessed pin.
    """

    floor_id: uuid.UUID
    floor_level: int
    bssid: str
    ssid: str
    frequency_mhz: int
    lat: float | None = None
    lng: float | None = None
    method: str
    reading_count: int
    max_rssi_dbm: int
    confidence: float | None = None
    low_confidence: bool | None = None
    spread_m: float | None = None
    position_determined: bool = False


class AccessPointRead(AccessPointOut):
    id: uuid.UUID
    survey_id: uuid.UUID
    computed_at: datetime


class CoverageRead(BaseModel):
    """One coverage grid. ``values`` is row-major, south row first, west column
    first; ``null`` means no data. ``origin_lat`` and ``origin_lng`` are the
    south-west corner. ``confidence`` has the same layout with 0 to 1 for how well
    readings back each cell (few or distant readings give less); ``null`` on grids
    processed before it existed, which should be read as 1."""

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
    confidence: list[float | None] | None = None
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


class CellGridOut(BaseModel):
    """A grid in the same layout as ``CoverageRead``: row-major, south row and
    west column first, ``null`` where there is no data. ``origin_lat`` and
    ``origin_lng`` are the south-west corner; ``north_lat`` and ``east_lng``
    the north-east corner."""

    origin_lat: float
    origin_lng: float
    north_lat: float
    east_lng: float
    cell_size_m: float
    cols: int
    rows: int
    values: list[float | None]


class RouterNetworkOut(BaseModel):
    """One BSSID of a router, with the network name it broadcasts."""

    bssid: str
    ssid: str
    frequency_mhz: int
    reading_count: int
    max_rssi_dbm: int


class RouterOut(BaseModel):
    """One router on one floor (FR-27, FR-28).

    ``number`` is the same on every floor of the survey (1 = the strongest).
    ``lat`` and ``lng`` are its estimated position when it is placed on this
    floor, else null; ``confidence`` and ``low_confidence`` come from that
    estimate. ``footprint`` is the strongest value of its BSSIDs per cell;
    ``area_m2`` counts cells at or above the dead threshold, ``good_area_m2``
    those at or above the good one."""

    router_id: str
    number: int
    label: str
    ssids: list[str]
    networks: list[RouterNetworkOut]
    max_rssi_dbm: int
    lat: float | None = None
    lng: float | None = None
    confidence: float | None = None
    low_confidence: bool | None = None
    area_m2: float
    good_area_m2: float
    footprint: CellGridOut


class RouterLinkOut(BaseModel):
    """A straight link between two routers of a chain. ``status`` is ``dead``
    when part of it is below the dead threshold, ``weak`` when part is below
    the good one, ``no_data`` when nothing on it was measured, else
    ``covered``. The meters add up to about ``length_m``."""

    from_router: str
    to_router: str
    length_m: float
    min_rssi_dbm: float | None
    weak_m: float
    dead_m: float
    no_data_m: float
    status: Literal["covered", "weak", "dead", "no_data"]


class RouterChainOut(BaseModel):
    """Routers on one floor that broadcast the same network name (FR-29).

    ``gaps`` holds the chain's best signal only on the weak and dead cells
    along its links; null when there is none (or fewer than two routers are
    placed on the floor)."""

    ssids: list[str]
    router_ids: list[str]
    links: list[RouterLinkOut]
    weak_cells: int
    dead_cells: int
    gap_area_m2: float
    gaps: CellGridOut | None


class RouterFloorOut(BaseModel):
    floor_id: uuid.UUID
    floor_level: int
    floor_label: str
    router_count: int
    routers: list[RouterOut]
    chains: list[RouterChainOut]


class ExtendedRouterOut(BaseModel):
    """One router of an extended network, on one floor.

    ``role`` is ``likely_main`` or ``extender`` (an estimate; see
    ``main_heuristic``). ``lat`` and ``lng`` are null when the position is
    not determined; the router still appears in the list."""

    router_id: str
    number: int
    label: str
    role: Literal["likely_main", "extender"]
    max_rssi_dbm: int
    lat: float | None = None
    lng: float | None = None
    confidence: float | None = None
    low_confidence: bool | None = None
    position_determined: bool = False


class ExtendedNetworkFloorOut(BaseModel):
    """One floor of an extended network: its routers, the links between
    those that are placed, the gaps along those links, and ``coverage``, the
    merged heatmap of this network name on this floor."""

    floor_id: uuid.UUID
    floor_level: int
    floor_label: str
    likely_main: str | None
    routers: list[ExtendedRouterOut]
    links: list[RouterLinkOut]
    weak_cells: int
    dead_cells: int
    gap_area_m2: float
    gaps: CellGridOut | None
    coverage: CellGridOut | None


class ExtendedNetworkOut(BaseModel):
    """A named network served by two or more routers (an extended network).

    ``router_ids`` are in survey number order and count every floor.
    ``likely_main`` is that estimate for the whole network."""

    ssid: str
    router_ids: list[str]
    router_count: int
    likely_main: str | None
    floors: list[ExtendedNetworkFloorOut]


class RouterCoverageRead(BaseModel):
    """Router coverage mode of a processed survey (FR-27 to FR-29).

    ``router_count`` counts routers in the whole survey and ``bssid_count``
    the BSSIDs they were grouped from; ``grouping`` says how.
    ``extended_networks`` lists named SSIDs served by two or more routers,
    which is what router mode opens on. ``floors`` (every router and the
    older combined chains) is kept so existing clients keep working.
    ``main_heuristic`` explains the "likely main" guess."""

    survey_id: uuid.UUID
    thresholds: Thresholds
    router_count: int
    bssid_count: int
    grouping: str
    gap_corridor_m: float
    main_heuristic: str = ""
    floors: list[RouterFloorOut]
    extended_networks: list[ExtendedNetworkOut] = []
