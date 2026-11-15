"""GeoJSON and CSV output for a processed survey (FR-16a, FR-21)."""

import csv
import io
import uuid
from collections.abc import Iterable
from datetime import UTC
from typing import Any

import numpy as np
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.building import Floor
from app.models.result import AccessPointEstimate, CoverageGrid
from app.models.survey import ScanReading, Survey
from app.services import processing as proc
from app.services.results import floors_of

COORD_DECIMALS = 7
CSV_COLUMNS = [
    "client_id",
    "floor_level",
    "lat",
    "lng",
    "accuracy_m",
    "bssid",
    "ssid",
    "rssi_dbm",
    "frequency_mhz",
    "scanned_at",
]
# Spreadsheet programs run cells that start with these characters as formulas.
_FORMULA_PREFIXES = ("=", "+", "-", "@", "\t", "\r")


def _point(lng: float, lat: float) -> dict[str, Any]:
    return {
        "type": "Point",
        "coordinates": [round(lng, COORD_DECIMALS), round(lat, COORD_DECIMALS)],
    }


def _cell_polygon(
    survey: Survey, grid: CoverageGrid, col: int, row: int
) -> dict[str, Any]:
    """Closed ring (5 points, counter-clockwise) of one cell as ``[lng, lat]``."""
    origin_x, origin_y = proc.to_local(
        grid.origin_lat, grid.origin_lng, survey.origin_lat, survey.origin_lng
    )
    size = grid.cell_size_m
    west = origin_x + col * size
    south = origin_y + row * size
    corners = [
        (west, south),
        (west + size, south),
        (west + size, south + size),
        (west, south + size),
        (west, south),
    ]
    ring = []
    for x, y in corners:
        lat, lng = proc.to_geo(x, y, survey.origin_lat, survey.origin_lng)
        ring.append([round(lng, COORD_DECIMALS), round(lat, COORD_DECIMALS)])
    return {"type": "Polygon", "coordinates": [ring]}


def coverage_features(
    db: Session,
    survey: Survey,
    floors: dict[uuid.UUID, Floor],
    bssid: str | None,
    floor_ids: set[uuid.UUID],
) -> list[dict[str, Any]]:
    stmt = select(CoverageGrid).where(
        CoverageGrid.survey_id == survey.id, CoverageGrid.floor_id.in_(floor_ids)
    )
    stmt = stmt.where(
        CoverageGrid.bssid.is_(None) if bssid is None else CoverageGrid.bssid == bssid
    )
    features = []
    for grid in sorted(db.scalars(stmt), key=lambda g: floors[g.floor_id].level):
        level_of_floor = floors[grid.floor_id].level
        values = np.array(
            [np.nan if v is None else v for v in grid.values], dtype=float
        )
        for index in np.flatnonzero(~np.isnan(values)):
            row, col = divmod(int(index), grid.cols)
            rssi = float(values[index])
            features.append(
                {
                    "type": "Feature",
                    "geometry": _cell_polygon(survey, grid, col, row),
                    "properties": {
                        "kind": "coverage",
                        "rssi_dbm": rssi,
                        "level": proc.level_for(
                            rssi, grid.good_threshold_dbm, grid.dead_threshold_dbm
                        ),
                        "floor_level": level_of_floor,
                        "bssid": None if grid.bssid is None else str(grid.bssid),
                    },
                }
            )
    return features


def access_point_features(
    db: Session,
    survey: Survey,
    floors: dict[uuid.UUID, Floor],
    bssid: str | None,
    floor_ids: set[uuid.UUID],
) -> list[dict[str, Any]]:
    stmt = select(AccessPointEstimate).where(
        AccessPointEstimate.survey_id == survey.id,
        AccessPointEstimate.floor_id.in_(floor_ids),
    )
    if bssid is not None:
        stmt = stmt.where(AccessPointEstimate.bssid == bssid)
    aps = sorted(db.scalars(stmt), key=lambda a: (floors[a.floor_id].level, a.bssid))
    return [
        {
            "type": "Feature",
            "geometry": _point(ap.lng, ap.lat),
            "properties": {
                "kind": "access_point",
                "ssid": ap.ssid,
                "bssid": str(ap.bssid),
                "floor_level": floors[ap.floor_id].level,
                "rssi_dbm": ap.max_rssi_dbm,
                "method": ap.method,
                "reading_count": ap.reading_count,
            },
        }
        for ap in aps
    ]


def reading_features(
    db: Session,
    survey: Survey,
    floors: dict[uuid.UUID, Floor],
    bssid: str | None,
    floor_ids: set[uuid.UUID],
) -> list[dict[str, Any]]:
    stmt = select(ScanReading).where(
        ScanReading.survey_id == survey.id, ScanReading.floor_id.in_(floor_ids)
    )
    if bssid is not None:
        stmt = stmt.where(ScanReading.bssid == bssid)
    stmt = stmt.order_by(ScanReading.scanned_at, ScanReading.id)
    return [
        {
            "type": "Feature",
            "geometry": _point(reading.lng, reading.lat),
            "properties": {
                "kind": "reading",
                "ssid": reading.ssid,
                "bssid": str(reading.bssid),
                "floor_level": floors[reading.floor_id].level,
                "rssi_dbm": reading.rssi_dbm,
                "scanned_at": reading.scanned_at.astimezone(UTC).isoformat(),
            },
        }
        for reading in db.scalars(stmt)
    ]


def geojson(
    db: Session,
    survey: Survey,
    *,
    include: Iterable[str],
    floor_level: int | None,
    bssid: str | None,
) -> dict[str, Any]:
    """FeatureCollection of cells, access points and readings. Every feature has a
    ``floor_level`` property, so a map can show one layer per floor."""
    floors = floors_of(db, survey)
    floor_ids = {
        floor.id
        for floor in floors.values()
        if floor_level is None or floor.level == floor_level
    }
    wanted = set(include)
    features: list[dict[str, Any]] = []
    if "cells" in wanted:
        features += coverage_features(db, survey, floors, bssid, floor_ids)
    if "access_points" in wanted:
        features += access_point_features(db, survey, floors, bssid, floor_ids)
    if "readings" in wanted:
        features += reading_features(db, survey, floors, bssid, floor_ids)
    return {"type": "FeatureCollection", "features": features}


def _csv_text(value: str) -> str:
    return "'" + value if value.startswith(_FORMULA_PREFIXES) else value


def readings_csv(db: Session, survey: Survey) -> str:
    floors = floors_of(db, survey)
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\r\n")
    writer.writerow(CSV_COLUMNS)
    stmt = (
        select(ScanReading)
        .where(ScanReading.survey_id == survey.id)
        .order_by(ScanReading.scanned_at, ScanReading.id)
    )
    for r in db.scalars(stmt):
        writer.writerow(
            [
                r.client_id,
                floors[r.floor_id].level,
                r.lat,
                r.lng,
                "" if r.accuracy_m is None else r.accuracy_m,
                str(r.bssid),
                _csv_text(r.ssid),
                r.rssi_dbm,
                r.frequency_mhz,
                r.scanned_at.astimezone(UTC).isoformat(),
            ]
        )
    return out.getvalue()
