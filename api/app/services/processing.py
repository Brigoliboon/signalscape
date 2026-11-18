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
# 5 m (down from 10 m): beyond a few steps a reading says little about a cell, and
# a wide radius painted guessed values into areas nobody walked. A cell with no
# reading inside the radius stays "no data".
IDW_RADIUS_M = 5.0
# Confidence of a cell (0 to 1) = min(1, n / CONFIDENCE_FULL_READINGS)
# * (1 - nearest / radius), n being the cleaned readings within the radius and
# nearest the distance to the closest one. Four readings, one of them on the cell
# center, give full confidence.
CONFIDENCE_FULL_READINGS = 4
CONFIDENCE_DECIMALS = 2
# A survey whose positions span more than this many cells in one direction is
# almost certainly a bad GPS fix, so it is refused instead of building a huge grid.
MAX_GRID_DIM = 1000
# Positions within the same square of this size count as one "position" when taking
# the strongest signal across networks.
POSITION_SQUARE_M = 0.5
_CHUNK_ELEMENTS = 2_000_000
_EXACT_D2 = 1e-9

# Access points (FR-23 to FR-25). Each one is placed by a log-distance path-loss
# fit: rssi = P0 - 10 n log10(d), d the 3D distance to the access point, P0 the
# RSSI at 1 m and n the path-loss exponent. Position, P0 and n are fitted by
# weighted least squares (Levenberg-Marquardt), starting at the weighted centroid.
AP_METHOD = "path_loss_lsq"
# Used when there are too few readings to fit, or the fit fails.
AP_FALLBACK_METHOD = "weighted_centroid"
# The centroid start point uses the strongest readings only.
AP_TOP_READINGS = 10
# A placement is confident with at least this many readings on its floor, spread
# over at least this many meters (FR-24). Spread = 2 x the RMS distance of the
# readings from their mean position, which is the distance between them for two
# readings and about the width of the walked area for more.
AP_MIN_READINGS = 5
AP_MIN_SPREAD_M = 3.0
# Defaults the fit is pulled towards (as weak priors) when the data cannot tell.
AP_DEFAULT_P0_DBM = -40.0
AP_DEFAULT_EXPONENT = 3.0
AP_P0_RANGE_DBM = (-60.0, -20.0)
AP_EXPONENT_RANGE = (2.0, 4.0)
_AP_PRIOR_SIGMA_P0_DB = 10.0
_AP_PRIOR_SIGMA_EXPONENT = 0.5
# Height of the access point above the phone, so d never reaches 0 under it.
AP_HEIGHT_M = 1.0
# A fit needs at least this many readings; fewer use the centroid.
AP_FIT_MIN_READINGS = 3
# Only the strongest readings are fitted, which keeps big surveys fast.
AP_FIT_MAX_READINGS = 200
# The fitted point may sit outside the walked area (NFR-5), but never further
# than this from the centroid start point. A clamped fit is low confidence.
AP_MAX_OFFSET_M = 25.0
_AP_MAX_ITERATIONS = 60
# A walk narrower than this (2 x the RMS distance across its main direction, for
# example one straight corridor) cannot tell which side of the line the access
# point is on, so the fitted point is put back on the line.
AP_MIN_WIDTH_M = 1.0
# Confidence score: the fit's RMS residual (dB) at which the fit factor is 0.5.
AP_RESIDUAL_HALF_DB = 8.0
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
    ``confidence`` (same layout, 0 to 1, ``nan`` with no data) says how well
    readings back each cell; ``None`` means it was not computed.
    """

    origin_x: float
    origin_y: float
    cols: int
    rows: int
    cell_size: float
    values: np.ndarray = field(repr=False)
    confidence: np.ndarray | None = field(default=None, repr=False)


def cell_confidence(
    count: np.ndarray, nearest: np.ndarray, radius: float
) -> np.ndarray:
    """``min(1, count / 4) * (1 - nearest / radius)``, clamped to 0..1.

    ``count`` is the number of readings within ``radius`` and ``nearest`` the
    distance to the closest one (any value where ``count`` is 0, which gives 0).
    """
    spread = np.clip(1.0 - nearest / radius, 0.0, 1.0)
    shared = np.minimum(1.0, count / CONFIDENCE_FULL_READINGS)
    return np.clip(shared * spread, 0.0, 1.0)


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
    method: str = AP_METHOD
    # 0 to 1: how much the placement can be trusted (count, spread and fit).
    confidence: float = 0.0
    # True below AP_MIN_READINGS or AP_MIN_SPREAD_M, or when the fit failed (FR-24).
    low_confidence: bool = True
    spread_m: float = 0.0


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
    center is on a reading takes that reading's value. The grid also carries a
    per-cell confidence (see :func:`cell_confidence`).
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
    confidence = np.full(cols * rows, np.nan)
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
        count = in_range.sum(axis=1)
        nearest = np.sqrt(np.where(in_range, d2, np.inf).min(axis=1))
        nearest[count == 0] = radius
        conf = np.round(cell_confidence(count, nearest, radius), CONFIDENCE_DECIMALS)
        conf[count == 0] = np.nan
        confidence[start : start + block] = conf
    return Grid(origin_x, origin_y, cols, rows, cell_size, out, confidence)


def level_for(rssi: float, good_dbm: int, dead_dbm: int) -> str:
    """good at or above ``good_dbm``, dead below ``dead_dbm``, fair in between."""
    if rssi >= good_dbm:
        return LEVEL_GOOD
    if rssi < dead_dbm:
        return LEVEL_DEAD
    return LEVEL_FAIR


def position_determined(max_rssi_dbm: float | int, good_dbm: int) -> bool:
    """True when at least one reading is in the good/strong band (FR-15).

    The good band is at or above ``good_dbm`` (default -67 dBm), the strong end
    of the heatmap colour ramp (red at -30 dBm, green at the -67 dBm stop).
    ``max_rssi_dbm`` is the access point's strongest reading, so this is the
    same as "at least one strong reading".
    """
    return max_rssi_dbm >= good_dbm


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


def weighted_centroid(readings: list[Reading]) -> tuple[float, float]:
    """Power-weighted centroid of the 10 strongest readings, ``10^(rssi/10)``.

    The v1.0 estimate (FR-14); now the start point of the fit and its fallback.
    """
    top = sorted(readings, key=lambda r: (-r.rssi, r.t))[:AP_TOP_READINGS]
    weights = np.array([10 ** (r.rssi / 10) for r in top])
    x = float(np.average([r.x for r in top], weights=weights))
    y = float(np.average([r.y for r in top], weights=weights))
    return x, y


def spread_m(xs: np.ndarray, ys: np.ndarray) -> float:
    """2 x the RMS distance of the points from their mean (0 for one point)."""
    if xs.size == 0:
        return 0.0
    d2 = (xs - xs.mean()) ** 2 + (ys - ys.mean()) ** 2
    return float(2.0 * math.sqrt(d2.mean()))


@dataclass(frozen=True)
class PathLossFit:
    x: float
    y: float
    p0_dbm: float
    exponent: float
    rms_db: float
    clamped: bool


def path_loss_distance(rssi: float, p0_dbm: float, exponent: float) -> float:
    """Range from RSSI by the log-distance model: ``10^((P0 - rssi) / (10 n))``."""
    return 10 ** ((p0_dbm - rssi) / (10 * exponent))


def _fit_starts(
    xs: np.ndarray, ys: np.ndarray, start: tuple[float, float]
) -> list[tuple[float, float]]:
    """The centroid, then 8 points around it one spread away (at least 3 m).

    A single start on the walked path often stops in a local minimum inside the
    walked area, or on the line of a straight corridor walk.
    """
    radius = max(spread_m(xs, ys), AP_MIN_SPREAD_M)
    return [start] + [
        (
            start[0] + radius * math.cos(k * math.pi / 4),
            start[1] + radius * math.sin(k * math.pi / 4),
        )
        for k in range(8)
    ]


def _solve(residuals, theta: np.ndarray) -> tuple[float, np.ndarray] | None:
    """Levenberg-Marquardt from ``theta``; ``(cost, theta)`` or None."""
    res, jac = residuals(theta)
    cost = float(res @ res)
    damping = 1e-3
    for _ in range(_AP_MAX_ITERATIONS):
        normal = jac.T @ jac
        step = np.linalg.solve(
            normal + damping * np.diag(np.diag(normal) + 1e-9), -jac.T @ res
        )
        candidate = theta + step
        new_res, new_jac = residuals(candidate)
        new_cost = float(new_res @ new_res)
        if not math.isfinite(new_cost):
            damping *= 10
            continue
        if new_cost < cost:
            done = cost - new_cost < 1e-9 * max(cost, 1.0)
            theta, res, jac, cost = candidate, new_res, new_jac, new_cost
            damping = max(damping / 10, 1e-9)
            if done:
                break
        else:
            damping *= 10
            if damping > 1e9:
                break
    if not (math.isfinite(cost) and np.all(np.isfinite(theta))):
        return None
    return cost, theta


def fit_path_loss(
    xs: np.ndarray,
    ys: np.ndarray,
    rssi: np.ndarray,
    start: tuple[float, float],
) -> PathLossFit | None:
    """Weighted least-squares fit of position, P0 and n (Levenberg-Marquardt).

    Residuals are in dB: ``P0 - 10 n log10(d_i) - rssi_i`` with
    ``d_i = sqrt(dx^2 + dy^2 + h^2)``. Strong readings weigh more (weight 1 at
    the strongest, falling by half every 10 dB weaker), since far, weak readings
    are the noisiest. P0 and n have weak priors at the defaults so that little or
    one-sided data keeps them sane; both are then clamped to their ranges, and the
    position to ``AP_MAX_OFFSET_M`` from ``start``. Returns None when the fit does
    not give finite numbers.
    """
    weights = 1.0 / (1.0 + (rssi.max() - rssi) / 10.0)
    sw = np.sqrt(weights)
    prior_sw = np.array([1 / _AP_PRIOR_SIGMA_P0_DB, 1 / _AP_PRIOR_SIGMA_EXPONENT])
    prior_mean = np.array([AP_DEFAULT_P0_DBM, AP_DEFAULT_EXPONENT])
    h2 = AP_HEIGHT_M**2

    def residuals(theta: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        x, y, p0, n = theta
        dx, dy = x - xs, y - ys
        d2 = dx * dx + dy * dy + h2
        log_d = 0.5 * np.log10(d2)
        res = sw * (p0 - 10 * n * log_d - rssi)
        jac = np.empty((xs.size, 4))
        k = -10 * n / math.log(10)
        jac[:, 0] = sw * k * dx / d2
        jac[:, 1] = sw * k * dy / d2
        jac[:, 2] = sw
        jac[:, 3] = sw * -10 * log_d
        prior_res = prior_sw * (theta[2:] - prior_mean)
        prior_jac = np.zeros((2, 4))
        prior_jac[0, 2], prior_jac[1, 3] = prior_sw
        return np.concatenate([res, prior_res]), np.vstack([jac, prior_jac])

    best: tuple[float, np.ndarray] | None = None
    for sx, sy in _fit_starts(xs, ys, start):
        found = _solve(
            residuals, np.array([sx, sy, AP_DEFAULT_P0_DBM, AP_DEFAULT_EXPONENT])
        )
        if found is not None and (best is None or found[0] < best[0]):
            best = found
    if best is None:
        return None
    theta = best[1]

    x, y, p0, n = (float(v) for v in theta)
    p0 = min(max(p0, AP_P0_RANGE_DBM[0]), AP_P0_RANGE_DBM[1])
    n = min(max(n, AP_EXPONENT_RANGE[0]), AP_EXPONENT_RANGE[1])
    offset = math.hypot(x - start[0], y - start[1])
    clamped = offset > AP_MAX_OFFSET_M
    if clamped:
        scale = AP_MAX_OFFSET_M / offset
        x = start[0] + (x - start[0]) * scale
        y = start[1] + (y - start[1]) * scale
    d = np.sqrt((x - xs) ** 2 + (y - ys) ** 2 + h2)
    predicted = p0 - 10 * n * np.log10(d)
    rms = float(np.sqrt(np.average((predicted - rssi) ** 2, weights=weights)))
    return PathLossFit(x, y, p0, n, rms, clamped)


def onto_walk_line(
    x: float, y: float, xs: np.ndarray, ys: np.ndarray
) -> tuple[float, float]:
    """``(x, y)`` moved onto the walk's main line when the walk is narrower than
    ``AP_MIN_WIDTH_M``; unchanged otherwise (or with fewer than 2 readings)."""
    if xs.size < 2:
        return x, y
    mx, my = float(xs.mean()), float(ys.mean())
    eigenvalues, eigenvectors = np.linalg.eigh(np.cov(np.vstack([xs, ys]), bias=True))
    if 2.0 * math.sqrt(max(float(eigenvalues[0]), 0.0)) >= AP_MIN_WIDTH_M:
        return x, y
    ux, uy = (float(v) for v in eigenvectors[:, 1])  # the main direction
    along = (x - mx) * ux + (y - my) * uy
    return mx + along * ux, my + along * uy


def placement_confidence(count: int, spread: float, rms_db: float | None) -> float:
    """0 to 1 = count factor x spread factor x fit factor, rounded to 2 places.

    Count and spread reach 1 at twice their minimums (10 readings, 6 m). The fit
    factor is ``1 / (1 + (rms / 8 dB)^2)``, or 0 when there was no fit.
    """
    count_f = min(1.0, count / (2 * AP_MIN_READINGS))
    spread_f = min(1.0, spread / (2 * AP_MIN_SPREAD_M))
    fit_f = 0.0 if rms_db is None else 1.0 / (1.0 + (rms_db / AP_RESIDUAL_HALF_DB) ** 2)
    return round(count_f * spread_f * fit_f, CONFIDENCE_DECIMALS)


def estimate_access_points(readings: list[Reading]) -> list[AccessPoint]:
    """Place each BSSID by a path-loss fit on the floor of its strongest reading.

    Every access point is returned. With fewer than ``AP_MIN_READINGS`` on that
    floor, less than ``AP_MIN_SPREAD_M`` of spread, or a fit that failed or had
    to be clamped, it is flagged ``low_confidence`` (FR-24). With too few
    readings to fit, or a failed fit, the weighted centroid is used instead and
    ``method`` says so.
    """
    by_bssid: dict[str, list[Reading]] = defaultdict(list)
    for reading in readings:
        by_bssid[reading.bssid].append(reading)

    estimates = []
    for bssid, group in sorted(by_bssid.items()):
        strongest = max(group, key=lambda r: (r.rssi, -r.t))
        on_floor = [r for r in group if r.floor_id == strongest.floor_id]
        start = weighted_centroid(on_floor)
        xs = np.array([r.x for r in on_floor])
        ys = np.array([r.y for r in on_floor])
        spread = spread_m(xs, ys)

        fit = None
        if len(on_floor) >= AP_FIT_MIN_READINGS:
            used = sorted(on_floor, key=lambda r: (-r.rssi, r.t))[:AP_FIT_MAX_READINGS]
            fit = fit_path_loss(
                np.array([r.x for r in used]),
                np.array([r.y for r in used]),
                np.array([r.rssi for r in used], dtype=float),
                start,
            )
        if fit is None:
            (x, y), method, rms = start, AP_FALLBACK_METHOD, None
        else:
            x, y = onto_walk_line(fit.x, fit.y, xs, ys)
            method, rms = AP_METHOD, fit.rms_db
        low = (
            fit is None
            or fit.clamped
            or len(on_floor) < AP_MIN_READINGS
            or spread < AP_MIN_SPREAD_M
        )
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
                method=method,
                confidence=placement_confidence(len(on_floor), spread, rms),
                low_confidence=low,
                spread_m=round(spread, 2),
            )
        )
    return estimates
