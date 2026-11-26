"""Merge selected processed surveys onto one campus map (FR-34, FR-35, NFR-6).

The readings of the selection are cleaned and interpolated together with the
same math a single survey uses. Nothing is stored: the result is computed on
request so a DTO selection can be explored without copying data.
"""

import uuid
from collections import Counter
from datetime import UTC, datetime

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.building import Floor
from app.models.survey import ScanReading, Survey
from app.models.user import User
from app.schemas.result import AccessPointOut, FloorSummary, Thresholds
from app.schemas.site import (
    ConsolidatedGrid,
    ConsolidationRead,
    OutdoorPoint,
)
from app.services import processing as proc
from app.services.results import compute
from app.services.surveys import get_survey_or_404

# Readings in the site's outdoor polygon are grouped under this synthetic id.
OUTDOOR_AREA_ID = uuid.UUID(int=0)
OUTDOOR_LABEL = "Outdoor"


def _corner(point: OutdoorPoint | dict) -> tuple[float, float]:
    if isinstance(point, dict):
        return float(point["lat"]), float(point["lng"])
    return float(point.lat), float(point.lng)


def _inside_polygon(lat: float, lng: float, polygon: list[OutdoorPoint | dict]) -> bool:
    """Ray casting on the lng/lat plane; boundary points count as inside."""
    corners = [_corner(point) for point in polygon]
    inside = False
    n = len(corners)
    for i in range(n):
        a_lat, a_lng = corners[i]
        b_lat, b_lng = corners[(i + 1) % n]
        if (a_lat, a_lng) == (b_lat, b_lng):
            continue
        cross = (b_lng - a_lng) * (lat - a_lat) - (b_lat - a_lat) * (lng - a_lng)
        if abs(cross) < 1e-10 and (
            min(a_lat, b_lat) <= lat <= max(a_lat, b_lat)
            and min(a_lng, b_lng) <= lng <= max(a_lng, b_lng)
        ):
            return True
        if (a_lat > lat) != (b_lat > lat):
            edge_lng = a_lng + (lat - a_lat) * (b_lng - a_lng) / (b_lat - a_lat)
            if lng < edge_lng:
                inside = not inside
    return inside


def _load_readings(
    db: Session,
    surveys: list[Survey],
    origin_lat: float,
    origin_lng: float,
    outdoor_area: list[OutdoorPoint] | None,
) -> list[proc.Reading]:
    ids = [survey.id for survey in surveys]
    stmt = select(
        ScanReading.survey_id,
        ScanReading.floor_id,
        ScanReading.bssid,
        ScanReading.ssid,
        ScanReading.frequency_mhz,
        ScanReading.lat,
        ScanReading.lng,
        ScanReading.rssi_dbm,
        ScanReading.scanned_at,
    ).where(ScanReading.survey_id.in_(ids))
    readings = []
    for row in db.execute(stmt):
        lat, lng = float(row.lat), float(row.lng)
        area_id = (
            OUTDOOR_AREA_ID
            if outdoor_area and _inside_polygon(lat, lng, outdoor_area)
            else row.floor_id
        )
        x, y = proc.to_local(lat, lng, origin_lat, origin_lng)
        readings.append(
            proc.Reading(
                floor_id=area_id,
                bssid=str(row.bssid).lower(),
                ssid=row.ssid,
                frequency_mhz=row.frequency_mhz,
                x=x,
                y=y,
                rssi=float(row.rssi_dbm),
                t=row.scanned_at.timestamp(),
            )
        )
    return readings


def consolidate(
    db: Session,
    site,
    survey_ids: list[uuid.UUID],
    user: User,
    thresholds: Thresholds,
) -> ConsolidationRead:
    surveys = [get_survey_or_404(db, user, survey_id) for survey_id in survey_ids]
    site_building_ids = {building.id for building in site.buildings}
    for survey in surveys:
        if survey.building_id not in site_building_ids:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Every survey must belong to a building in this site",
            )

    origin = surveys[0]
    raw = _load_readings(
        db, surveys, origin.origin_lat, origin.origin_lng, site.outdoor_area
    )
    try:
        computation = compute(raw, thresholds, per_network=False)
    except proc.ProcessingError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(exc)
        ) from exc

    floor_ids = {reading.floor_id for reading in raw}
    floors = {
        floor.id: floor
        for floor in db.scalars(
            select(Floor).where(Floor.id.in_(floor_ids - {OUTDOOR_AREA_ID}))
        )
    }

    def label(area_id: uuid.UUID) -> tuple[int, str]:
        if area_id == OUTDOOR_AREA_ID:
            return 0, OUTDOOR_LABEL
        floor = floors[area_id]
        return floor.level, floor.label

    grids = []
    summaries = []
    ap_counts = Counter(ap.floor_id for ap in computation.access_points)
    for result in sorted(computation.floors, key=lambda r: label(r.floor_id)[0]):
        level, name = label(result.floor_id)
        strongest = next((g for g in result.grids if g.bssid is None), None)
        for item in result.grids:
            lat, lng = proc.to_geo(
                item.grid.origin_x,
                item.grid.origin_y,
                origin.origin_lat,
                origin.origin_lng,
            )
            grids.append(
                ConsolidatedGrid(
                    floor_id=item.floor_id,
                    floor_level=level,
                    floor_label=name,
                    bssid=item.bssid,
                    method=proc.GRID_METHOD,
                    cell_size_m=item.grid.cell_size,
                    origin_lat=lat,
                    origin_lng=lng,
                    cols=item.grid.cols,
                    rows=item.grid.rows,
                    values=item.values,
                    confidence=item.confidence,
                    good_pct=item.good_pct,
                    fair_pct=item.fair_pct,
                    dead_pct=item.dead_pct,
                    thresholds=thresholds,
                    raw_reading_count=item.raw_count,
                    cleaned_reading_count=item.cleaned_count,
                )
            )
        summaries.append(
            FloorSummary(
                floor_id=result.floor_id,
                floor_level=level,
                floor_label=name,
                floor_height_m=(
                    0.0
                    if result.floor_id == OUTDOOR_AREA_ID
                    else float(floors[result.floor_id].height_m)
                ),
                raw_reading_count=result.raw_count,
                cleaned_reading_count=result.cleaned_count,
                area_covered_m2=(
                    strongest.covered * strongest.grid.cell_size**2
                    if strongest
                    else 0.0
                ),
                good_pct=strongest.good_pct if strongest else 0.0,
                fair_pct=strongest.fair_pct if strongest else 0.0,
                dead_pct=strongest.dead_pct if strongest else 0.0,
                thresholds=thresholds if strongest else None,
                access_point_count=ap_counts[result.floor_id],
            )
        )

    access_points = []
    for ap in sorted(computation.access_points, key=lambda a: a.bssid):
        lat, lng = proc.to_geo(ap.x, ap.y, origin.origin_lat, origin.origin_lng)
        determined, lat, lng = _position(ap.max_rssi_dbm, thresholds.good_dbm, lat, lng)
        access_points.append(
            AccessPointOut(
                floor_id=ap.floor_id,
                floor_level=label(ap.floor_id)[0],
                bssid=ap.bssid,
                ssid=ap.ssid,
                frequency_mhz=ap.frequency_mhz,
                lat=lat,
                lng=lng,
                method=ap.method,
                reading_count=ap.reading_count,
                max_rssi_dbm=ap.max_rssi_dbm,
                confidence=ap.confidence,
                low_confidence=ap.low_confidence,
                spread_m=ap.spread_m,
                position_determined=determined,
            )
        )

    return ConsolidationRead(
        site_id=site.id,
        survey_ids=survey_ids,
        computed_at=datetime.now(UTC),
        thresholds=thresholds,
        floors=summaries,
        grids=grids,
        access_points=access_points,
    )


def _position(good_rssi: int, good_dbm: int, lat: float, lng: float):
    if proc.position_determined(good_rssi, good_dbm):
        return True, lat, lng
    return False, None, None
