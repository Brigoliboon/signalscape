"""Pure math for survey processing (DESIGN.md section 5). No database access.

Positions come in as latitude and longitude. They are projected to local meters
around the survey origin (equirectangular), cleaned, interpolated and converted
back. Everything here works on plain Python values and NumPy arrays so it can be
tested on known inputs.
"""

import math
import statistics
import uuid
from collections import defaultdict
from dataclasses import dataclass, field

import numpy as np

EARTH_RADIUS_M = 6_371_008.8

# Cleaning (DESIGN.md: "Data cleaning").
MIN_VALID_DBM = -100
MAX_VALID_DBM = -20
MERGE_RADIUS_M = 1.0
MERGE_WINDOW_S = 10.0
OUTLIER_RADIUS_M = 3.0
OUTLIER_MAD_FACTOR = 2.5
# Fewer neighbors than this (the reading itself included) is too little to judge.
OUTLIER_MIN_NEIGHBORS = 3
# When the neighbors agree almost exactly, MAD is 0 and every tiny difference would
# look like an outlier, so MAD is never taken below this many dB.
MIN_MAD_DB = 2.0
INVALID_BSSIDS = frozenset({"00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"})

# Coverage (IDW).
CELL_SIZE_M = 1.0
IDW_RADIUS_M = 10.0
# A survey whose positions span more than this many cells in one direction is
# almost certainly a bad GPS fix, so it is refused instead of building a huge grid.
MAX_GRID_DIM = 1000
# Positions within the same square of this size count as one "position" when taking
# the strongest signal across networks.
POSITION_SQUARE_M = 0.5
_CHUNK_ELEMENTS = 2_000_000
_EXACT_D2 = 1e-9

# Access points.
AP_TOP_READINGS = 10
AP_METHOD = "weighted_centroid"
GRID_METHOD = "idw"

LEVEL_GOOD = "good"
LEVEL_FAIR = "fair"
LEVEL_DEAD = "dead"


class ProcessingError(ValueError):
    """The data cannot be processed (for example positions that are far apart)."""


@dataclass(frozen=True)
class Reading:
    """One scan result with its position in local meters."""

    floor_id: uuid.UUID
    bssid: str
    ssid: str
    frequency_mhz: int
    x: float
    y: float
    rssi: float
    t: float  # seconds


@dataclass
class CleaningStats:
    raw: int = 0
    out_of_range: int = 0
    merged: int = 0
    outliers: int = 0
    kept: int = 0


@dataclass
class Grid:
    """Row-major grid of dBm values; ``nan`` where there is no data.

    ``origin_x`` and ``origin_y`` are the south-west corner in local meters.
    """

    origin_x: float
    origin_y: float
    cols: int
    rows: int
    cell_size: float
    values: np.ndarray = field(repr=False)


@dataclass(frozen=True)
class AccessPoint:
    floor_id: uuid.UUID
    bssid: str
    ssid: str
    frequency_mhz: int
    x: float
    y: float
    reading_count: int
    max_rssi_dbm: int


# --- projection -------------------------------------------------------------


def to_local(lat: float, lng: float, origin_lat: float, origin_lng: float):
    """Project lat/lng to ``(x east, y north)`` meters around the origin."""
    y = math.radians(lat - origin_lat) * EARTH_RADIUS_M
    x = (
        math.radians(lng - origin_lng)
        * EARTH_RADIUS_M
        * math.cos(math.radians(origin_lat))
    )
    return x, y


def to_geo(x: float, y: float, origin_lat: float, origin_lng: float):
    """Inverse of :func:`to_local`. Returns ``(lat, lng)``."""
    lat = origin_lat + math.degrees(y / EARTH_RADIUS_M)
    lng = origin_lng + math.degrees(
        x / (EARTH_RADIUS_M * math.cos(math.radians(origin_lat)))
    )
    return lat, lng


# --- cleaning ---------------------------------------------------------------


def _group_by_floor_and_bssid(
    readings: list[Reading],
) -> dict[tuple[uuid.UUID, str], list[Reading]]:
    groups: dict[tuple[uuid.UUID, str], list[Reading]] = defaultdict(list)
    for reading in readings:
        groups[(reading.floor_id, reading.bssid)].append(reading)
    return groups


def merge_repeats(readings: list[Reading]) -> list[Reading]:
    """Merge repeat scans of one access point on one floor.

    Scans of the same BSSID within 1 m and 10 s of the first scan of a cluster
    become one reading: mean position, median RSSI, time of the first scan.
    """
    merged: list[Reading] = []
    for group in _group_by_floor_and_bssid(readings).values():
        ordered = sorted(group, key=lambda r: r.t)
        clusters: list[list[Reading]] = []
        open_clusters: list[list[Reading]] = []
        for reading in ordered:
            open_clusters = [
                c for c in open_clusters if reading.t - c[0].t <= MERGE_WINDOW_S
            ]
            for cluster in open_clusters:
                anchor = cluster[0]
                if math.hypot(reading.x - anchor.x, reading.y - anchor.y) <= (
                    MERGE_RADIUS_M
                ):
                    cluster.append(reading)
                    break
            else:
                cluster = [reading]
                clusters.append(cluster)
                open_clusters.append(cluster)
        for cluster in clusters:
            first = cluster[0]
            merged.append(
                Reading(
                    floor_id=first.floor_id,
                    bssid=first.bssid,
                    ssid=first.ssid,
                    frequency_mhz=first.frequency_mhz,
                    x=statistics.fmean(r.x for r in cluster),
                    y=statistics.fmean(r.y for r in cluster),
                    rssi=statistics.median(r.rssi for r in cluster),
                    t=first.t,
                )
            )
    return merged


def _neighbors(xy: np.ndarray, radius: float) -> list[np.ndarray]:
    """For every point, the indexes of all points within ``radius`` (itself
    included). Done in blocks so memory stays small."""
    count = len(xy)
    block = max(1, _CHUNK_ELEMENTS // max(count, 1))
    result: list[np.ndarray] = []
    for start in range(0, count, block):
        part = xy[start : start + block]
        d2 = ((part[:, None, :] - xy[None, :, :]) ** 2).sum(axis=2)
        close = d2 <= radius * radius
        result.extend(np.flatnonzero(row) for row in close)
    return result


def remove_outliers(readings: list[Reading]) -> list[Reading]:
    """Drop readings more than 2.5 MAD from the median of their 3 m neighborhood
    (same access point, same floor). Readings with fewer than 3 neighbors, the
    reading itself included, are kept."""
    kept: list[Reading] = []
    for group in _group_by_floor_and_bssid(readings).values():
        xy = np.array([[r.x, r.y] for r in group])
        rssi = np.array([r.rssi for r in group])
        for index, neighbors in enumerate(_neighbors(xy, OUTLIER_RADIUS_M)):
            if len(neighbors) < OUTLIER_MIN_NEIGHBORS:
                kept.append(group[index])
                continue
            values = rssi[neighbors]
            median = float(np.median(values))
            mad = float(np.median(np.abs(values - median)))
            limit = OUTLIER_MAD_FACTOR * max(mad, MIN_MAD_DB)
            if abs(rssi[index] - median) <= limit:
                kept.append(group[index])
    return kept


def clean_readings(readings: list[Reading]) -> tuple[list[Reading], CleaningStats]:
    """Range check, merge repeats, remove outliers. Returns the cleaned readings
    and how many were dropped at each step."""
    stats = CleaningStats(raw=len(readings))
    valid = [
        r
        for r in readings
        if MIN_VALID_DBM <= r.rssi <= MAX_VALID_DBM and r.bssid not in INVALID_BSSIDS
    ]
    stats.out_of_range = len(readings) - len(valid)
    merged = merge_repeats(valid)
    stats.merged = len(valid) - len(merged)
    cleaned = remove_outliers(merged)
    stats.outliers = len(merged) - len(cleaned)
    stats.kept = len(cleaned)
    cleaned.sort(key=lambda r: (r.t, r.bssid))
    return cleaned, stats


# --- coverage ---------------------------------------------------------------


def strongest_per_position(readings: list[Reading]) -> list[Reading]:
    """Keep the strongest reading at each position, so the grid shows the best
    signal available there whatever the network. Positions in the same 0.5 m
    square count as one position."""
    best: dict[tuple[uuid.UUID, int, int], list[Reading]] = defaultdict(list)
    for reading in readings:
        key = (
            reading.floor_id,
            math.floor(reading.x / POSITION_SQUARE_M),
            math.floor(reading.y / POSITION_SQUARE_M),
        )
        best[key].append(reading)
    result = []
    for members in best.values():
        top = max(members, key=lambda r: r.rssi)
        result.append(
            Reading(
                floor_id=top.floor_id,
                bssid=top.bssid,
                ssid=top.ssid,
                frequency_mhz=top.frequency_mhz,
                x=statistics.fmean(r.x for r in members),
                y=statistics.fmean(r.y for r in members),
                rssi=top.rssi,
                t=top.t,
            )
        )
    return result


def idw_grid(
    readings: list[Reading],
    cell_size: float = CELL_SIZE_M,
    radius: float = IDW_RADIUS_M,
) -> Grid:
    """Inverse distance weighting (power 2) on a regular grid.

    The grid covers the bounding box of the readings. Each cell takes the average
    of the readings within ``radius`` meters of its center, weighted by
    ``1 / d^2``; a cell with no reading in range stays ``nan``. A cell whose
    center is on a reading takes that reading's value.
    """
    if not readings:
        raise ProcessingError("There are no readings to interpolate")
    x = np.array([r.x for r in readings])
    y = np.array([r.y for r in readings])
    values = np.array([r.rssi for r in readings])

    origin_x = math.floor(x.min() / cell_size) * cell_size
    origin_y = math.floor(y.min() / cell_size) * cell_size
    cols = int(math.floor((x.max() - origin_x) / cell_size)) + 1
    rows = int(math.floor((y.max() - origin_y) / cell_size)) + 1
    if cols > MAX_GRID_DIM or rows > MAX_GRID_DIM:
        raise ProcessingError(
            f"Reading positions span more than {MAX_GRID_DIM * cell_size:.0f} m; "
            "check the survey's start GPS fix"
        )

    cell_x = origin_x + (np.arange(cols) + 0.5) * cell_size
    cell_y = origin_y + (np.arange(rows) + 0.5) * cell_size
    centers_x = np.tile(cell_x, rows)
    centers_y = np.repeat(cell_y, cols)

    out = np.full(cols * rows, np.nan)
    block = max(1, _CHUNK_ELEMENTS // len(readings))
    for start in range(0, len(out), block):
        cx = centers_x[start : start + block, None]
        cy = centers_y[start : start + block, None]
        d2 = (cx - x[None, :]) ** 2 + (cy - y[None, :]) ** 2
        in_range = d2 <= radius * radius
        exact = d2 < _EXACT_D2
        weights = np.where(in_range & ~exact, 1.0 / np.maximum(d2, _EXACT_D2), 0.0)
        total = weights.sum(axis=1)
        with np.errstate(invalid="ignore", divide="ignore"):
            part = (weights * values[None, :]).sum(axis=1) / total
        part[total == 0] = np.nan
        has_exact = exact.any(axis=1)
        if has_exact.any():
            exact_values = (exact * values[None, :]).sum(axis=1) / np.maximum(
                exact.sum(axis=1), 1
            )
            part[has_exact] = exact_values[has_exact]
        out[start : start + block] = part
    return Grid(origin_x, origin_y, cols, rows, cell_size, out)


def level_for(rssi: float, good_dbm: int, dead_dbm: int) -> str:
    """good at or above ``good_dbm``, dead below ``dead_dbm``, fair in between."""
    if rssi >= good_dbm:
        return LEVEL_GOOD
    if rssi < dead_dbm:
        return LEVEL_DEAD
    return LEVEL_FAIR


def level_shares(
    values: np.ndarray, good_dbm: int, dead_dbm: int
) -> tuple[float, float, float]:
    """Percent of covered cells that are good, fair and dead."""
    covered = values[~np.isnan(values)]
    if covered.size == 0:
        return 0.0, 0.0, 0.0
    good = int((covered >= good_dbm).sum())
    dead = int((covered < dead_dbm).sum())
    fair = covered.size - good - dead
    total = covered.size
    return 100 * good / total, 100 * fair / total, 100 * dead / total


def covered_cells(values: np.ndarray) -> int:
    return int((~np.isnan(values)).sum())


def grid_cell_corners(
    grid: Grid, col: int, row: int
) -> tuple[tuple[float, float], tuple[float, float]]:
    """South-west and north-east corners of a cell in local meters."""
    west = grid.origin_x + col * grid.cell_size
    south = grid.origin_y + row * grid.cell_size
    return (west, south), (west + grid.cell_size, south + grid.cell_size)


# --- access points ----------------------------------------------------------


def estimate_access_points(readings: list[Reading]) -> list[AccessPoint]:
    """Weighted centroid of the strongest readings of each BSSID.

    The access point is placed on the floor of its single strongest reading, using
    the 10 strongest readings on that floor with linear power ``10^(rssi/10)`` as
    weights.
    """
    by_bssid: dict[str, list[Reading]] = defaultdict(list)
    for reading in readings:
        by_bssid[reading.bssid].append(reading)

    estimates = []
    for bssid, group in sorted(by_bssid.items()):
        strongest = max(group, key=lambda r: (r.rssi, -r.t))
        on_floor = [r for r in group if r.floor_id == strongest.floor_id]
        top = sorted(on_floor, key=lambda r: (-r.rssi, r.t))[:AP_TOP_READINGS]
        weights = np.array([10 ** (r.rssi / 10) for r in top])
        x = float(np.average([r.x for r in top], weights=weights))
        y = float(np.average([r.y for r in top], weights=weights))
        estimates.append(
            AccessPoint(
                floor_id=strongest.floor_id,
                bssid=bssid,
                ssid=strongest.ssid,
                frequency_mhz=strongest.frequency_mhz,
                x=x,
                y=y,
                reading_count=len(on_floor),
                max_rssi_dbm=int(round(strongest.rssi)),
            )
        )
    return estimates
