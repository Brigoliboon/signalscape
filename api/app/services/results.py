"""Run processing for a survey, store and read its results.

The math lives in :mod:`app.services.processing`; this module loads readings,
calls it, and moves the output in and out of the database.
"""

import uuid
from collections import Counter
from dataclasses import dataclass, field
from datetime import UTC, datetime

import numpy as np
from fastapi import HTTPException, status
from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.models.building import Floor
from app.models.result import AccessPointEstimate, CoverageGrid
from app.models.survey import ScanReading, Survey, SurveyStatus
from app.models.user import User
from app.schemas.result import (
    AccessPointOut,
    CoverageRead,
    FloorSummary,
    ProcessResult,
    Thresholds,
)
from app.services import processing as proc

# Full processing needs a finished survey; a preview can run at any time.
PROCESSABLE_STATUSES = {SurveyStatus.COMPLETED, SurveyStatus.PROCESSED}


@dataclass
class GridResult:
    floor_id: uuid.UUID
    bssid: str | None
    grid: proc.Grid
    values: list[float | None]
    confidence: list[float | None]
    good_pct: float
    fair_pct: float
    dead_pct: float
    covered: int
    raw_count: int
    cleaned_count: int


@dataclass
class FloorResult:
    floor_id: uuid.UUID
    raw_count: int
    cleaned_count: int
    grids: list[GridResult] = field(default_factory=list)


@dataclass
class Computation:
    thresholds: Thresholds
    floors: list[FloorResult]
    access_points: list[proc.AccessPoint]


def not_processed() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_409_CONFLICT,
        detail="This survey has not been processed yet",
    )


def require_processed(survey: Survey) -> None:
    if survey.status != SurveyStatus.PROCESSED:
        raise not_processed()


def require_processable(survey: Survey) -> None:
    if survey.status not in PROCESSABLE_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"A {survey.status.value} survey cannot be processed yet; "
                "complete it first, or use preview=true"
            ),
        )


def floors_of(db: Session, survey: Survey) -> dict[uuid.UUID, Floor]:
    floors = db.scalars(select(Floor).where(Floor.building_id == survey.building_id))
    return {floor.id: floor for floor in floors}


def thresholds_for(db: Session, survey: Survey) -> Thresholds:
    """The surveyor's thresholds (FR-15)."""
    surveyor = db.get(User, survey.surveyor_id)
    assert surveyor is not None  # the foreign key guarantees it
    return Thresholds(
        good_dbm=surveyor.good_threshold_dbm, dead_dbm=surveyor.dead_threshold_dbm
    )


def stored_good_dbm(db: Session, survey: Survey) -> int:
    """The good threshold used when this survey was processed (FR-15).

    Taken from a stored coverage grid so it matches the heatmap of these
    results. Falls back to the surveyor's current setting.
    """
    value = db.scalar(
        select(CoverageGrid.good_threshold_dbm).where(
            CoverageGrid.survey_id == survey.id
        )
    )
    if value is not None:
        return int(value)
    return thresholds_for(db, survey).good_dbm


def access_point_location(
    lat: float, lng: float, max_rssi_dbm: int, good_dbm: int
) -> tuple[bool, float | None, float | None]:
    """Coordinates for the API: null until a strong (good-band) reading exists."""
    if proc.position_determined(max_rssi_dbm, good_dbm):
        return True, lat, lng
    return False, None, None


def load_readings(
    db: Session, survey: Survey, floor_id: uuid.UUID | None = None
) -> list[proc.Reading]:
    stmt = select(
        ScanReading.floor_id,
        ScanReading.bssid,
        ScanReading.ssid,
        ScanReading.frequency_mhz,
        ScanReading.lat,
        ScanReading.lng,
        ScanReading.rssi_dbm,
        ScanReading.scanned_at,
    ).where(ScanReading.survey_id == survey.id)
    if floor_id is not None:
        stmt = stmt.where(ScanReading.floor_id == floor_id)
    readings = []
    for row in db.execute(stmt):
        x, y = proc.to_local(row.lat, row.lng, survey.origin_lat, survey.origin_lng)
        readings.append(
            proc.Reading(
                floor_id=row.floor_id,
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


def _grid_result(
    floor_id: uuid.UUID,
    bssid: str | None,
    readings: list[proc.Reading],
    thresholds: Thresholds,
    raw_count: int,
    cleaned_count: int,
) -> GridResult:
    grid = proc.idw_grid(readings)
    # Round first so what is stored, classified and exported all agree.
    grid.values = np.round(grid.values, 1)
    good, fair, dead = proc.level_shares(
        grid.values, thresholds.good_dbm, thresholds.dead_dbm
    )
    return GridResult(
        floor_id=floor_id,
        bssid=bssid,
        grid=grid,
        values=[None if np.isnan(v) else float(v) for v in grid.values],
        confidence=[
            None if np.isnan(v) else float(v)
            for v in (
                grid.confidence
                if grid.confidence is not None
                else np.full(len(grid.values), np.nan)
            )
        ],
        good_pct=good,
        fair_pct=fair,
        dead_pct=dead,
        covered=proc.covered_cells(grid.values),
        raw_count=raw_count,
        cleaned_count=cleaned_count,
    )


def compute(
    readings: list[proc.Reading], thresholds: Thresholds, per_network: bool
) -> Computation:
    """Clean, interpolate and estimate access points for the given readings.

    ``per_network`` adds one grid per BSSID on top of the strongest-signal grid
    of each floor; a preview skips them to stay fast.
    """
    raw_by_floor = Counter(r.floor_id for r in readings)
    raw_by_network = Counter((r.floor_id, r.bssid) for r in readings)
    cleaned, _ = proc.clean_readings(readings)

    cleaned_by_floor: dict[uuid.UUID, list[proc.Reading]] = {}
    for reading in cleaned:
        cleaned_by_floor.setdefault(reading.floor_id, []).append(reading)

    floors = []
    for floor_id, raw_count in raw_by_floor.items():
        on_floor = cleaned_by_floor.get(floor_id, [])
        result = FloorResult(floor_id, raw_count, len(on_floor))
        if on_floor:
            result.grids.append(
                _grid_result(
                    floor_id,
                    None,
                    proc.strongest_per_position(on_floor),
                    thresholds,
                    raw_count,
                    len(on_floor),
                )
            )
            if per_network:
                by_bssid: dict[str, list[proc.Reading]] = {}
                for reading in on_floor:
                    by_bssid.setdefault(reading.bssid, []).append(reading)
                for bssid, group in sorted(by_bssid.items()):
                    result.grids.append(
                        _grid_result(
                            floor_id,
                            bssid,
                            group,
                            thresholds,
                            raw_by_network[(floor_id, bssid)],
                            len(group),
                        )
                    )
        floors.append(result)
    return Computation(thresholds, floors, proc.estimate_access_points(cleaned))


def persist(
    db: Session,
    survey: Survey,
    computation: Computation,
    now: datetime,
) -> None:
    """Replace the survey's stored results and mark it processed. The caller
    commits."""
    db.execute(delete(CoverageGrid).where(CoverageGrid.survey_id == survey.id))
    db.execute(
        delete(AccessPointEstimate).where(AccessPointEstimate.survey_id == survey.id)
    )
    for floor_result in computation.floors:
        for item in floor_result.grids:
            lat, lng = proc.to_geo(
                item.grid.origin_x,
                item.grid.origin_y,
                survey.origin_lat,
                survey.origin_lng,
            )
            db.add(
                CoverageGrid(
                    survey_id=survey.id,
                    floor_id=item.floor_id,
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
                    good_threshold_dbm=computation.thresholds.good_dbm,
                    dead_threshold_dbm=computation.thresholds.dead_dbm,
                    raw_reading_count=item.raw_count,
                    cleaned_reading_count=item.cleaned_count,
                    computed_at=now,
                )
            )
    for ap in computation.access_points:
        lat, lng = proc.to_geo(ap.x, ap.y, survey.origin_lat, survey.origin_lng)
        db.add(
            AccessPointEstimate(
                survey_id=survey.id,
                floor_id=ap.floor_id,
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
                computed_at=now,
            )
        )
    survey.status = SurveyStatus.PROCESSED
    survey.processed_at = now


# --- schemas from results ---------------------------------------------------


def _floor_summary(
    floor: Floor,
    result: FloorResult,
    thresholds: Thresholds,
    access_point_count: int,
) -> FloorSummary:
    strongest = next((g for g in result.grids if g.bssid is None), None)
    return FloorSummary(
        floor_id=floor.id,
        floor_level=floor.level,
        floor_label=floor.label,
        floor_height_m=float(floor.height_m),
        raw_reading_count=result.raw_count,
        cleaned_reading_count=result.cleaned_count,
        area_covered_m2=(
            strongest.covered * strongest.grid.cell_size**2 if strongest else 0.0
        ),
        good_pct=strongest.good_pct if strongest else 0.0,
        fair_pct=strongest.fair_pct if strongest else 0.0,
        dead_pct=strongest.dead_pct if strongest else 0.0,
        thresholds=thresholds if strongest else None,
        access_point_count=access_point_count,
    )


def computation_result(
    survey: Survey,
    computation: Computation,
    floors: dict[uuid.UUID, Floor],
    *,
    preview: bool,
    now: datetime,
) -> ProcessResult:
    ap_counts = Counter(ap.floor_id for ap in computation.access_points)
    ordered = sorted(computation.floors, key=lambda r: floors[r.floor_id].level)
    grids = []
    if preview:
        for floor_result in ordered:
            for item in floor_result.grids:
                lat, lng = proc.to_geo(
                    item.grid.origin_x,
                    item.grid.origin_y,
                    survey.origin_lat,
                    survey.origin_lng,
                )
                grids.append(
                    CoverageRead(
                        survey_id=survey.id,
                        floor_id=item.floor_id,
                        floor_level=floors[item.floor_id].level,
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
                        thresholds=computation.thresholds,
                        raw_reading_count=item.raw_count,
                        cleaned_reading_count=item.cleaned_count,
                        computed_at=now,
                    )
                )
    access_points = []
    good_dbm = computation.thresholds.good_dbm
    for ap in sorted(computation.access_points, key=lambda a: a.bssid):
        lat, lng = proc.to_geo(ap.x, ap.y, survey.origin_lat, survey.origin_lng)
        determined, lat, lng = access_point_location(
            lat, lng, ap.max_rssi_dbm, good_dbm
        )
        access_points.append(
            AccessPointOut(
                floor_id=ap.floor_id,
                floor_level=floors[ap.floor_id].level,
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
    return ProcessResult(
        survey_id=survey.id,
        status=survey.status.value,
        preview=preview,
        computed_at=now,
        thresholds=computation.thresholds,
        floors=[
            _floor_summary(
                floors[r.floor_id],
                r,
                computation.thresholds,
                ap_counts[r.floor_id],
            )
            for r in ordered
        ],
        access_points=access_points,
        grids=grids,
    )


def run_processing(
    db: Session,
    survey: Survey,
    *,
    preview: bool,
    floor_id: uuid.UUID | None,
) -> ProcessResult:
    floors = floors_of(db, survey)
    if floor_id is not None and floor_id not in floors:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not found")
    if not preview:
        require_processable(survey)
    readings = load_readings(db, survey, floor_id)
    thresholds = thresholds_for(db, survey)
    try:
        computation = compute(readings, thresholds, per_network=not preview)
    except proc.ProcessingError as error:
        raise HTTPException(status_code=422, detail=str(error)) from None
    now = datetime.now(UTC)
    if not preview:
        if not any(f.cleaned_count for f in computation.floors):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="This survey has no usable readings to process",
            )
        persist(db, survey, computation, now)
        db.commit()
        db.refresh(survey)
    return computation_result(survey, computation, floors, preview=preview, now=now)


# --- reading stored results -------------------------------------------------


def coverage_read(grid: CoverageGrid, floor: Floor) -> CoverageRead:
    return CoverageRead(
        survey_id=grid.survey_id,
        floor_id=grid.floor_id,
        floor_level=floor.level,
        bssid=None if grid.bssid is None else str(grid.bssid),
        method=grid.method,
        cell_size_m=grid.cell_size_m,
        origin_lat=grid.origin_lat,
        origin_lng=grid.origin_lng,
        cols=grid.cols,
        rows=grid.rows,
        values=grid.values,
        confidence=grid.confidence,
        good_pct=grid.good_pct,
        fair_pct=grid.fair_pct,
        dead_pct=grid.dead_pct,
        thresholds=Thresholds(
            good_dbm=grid.good_threshold_dbm, dead_dbm=grid.dead_threshold_dbm
        ),
        raw_reading_count=grid.raw_reading_count,
        cleaned_reading_count=grid.cleaned_reading_count,
        computed_at=grid.computed_at,
    )


def stored_summary(db: Session, survey: Survey) -> list[FloorSummary]:
    floors = floors_of(db, survey)
    raw = dict(
        db.execute(
            select(ScanReading.floor_id, func.count())
            .where(ScanReading.survey_id == survey.id)
            .group_by(ScanReading.floor_id)
        ).all()
    )
    grids = {
        g.floor_id: g
        for g in db.scalars(
            select(CoverageGrid).where(
                CoverageGrid.survey_id == survey.id, CoverageGrid.bssid.is_(None)
            )
        )
    }
    ap_counts = dict(
        db.execute(
            select(AccessPointEstimate.floor_id, func.count())
            .where(AccessPointEstimate.survey_id == survey.id)
            .group_by(AccessPointEstimate.floor_id)
        ).all()
    )
    summaries = []
    for floor in sorted((floors[floor_id] for floor_id in raw), key=lambda f: f.level):
        grid = grids.get(floor.id)
        covered = sum(1 for v in grid.values if v is not None) if grid else 0
        summaries.append(
            FloorSummary(
                floor_id=floor.id,
                floor_level=floor.level,
                floor_label=floor.label,
                floor_height_m=float(floor.height_m),
                raw_reading_count=raw[floor.id],
                cleaned_reading_count=grid.cleaned_reading_count if grid else 0,
                area_covered_m2=covered * grid.cell_size_m**2 if grid else 0.0,
                good_pct=grid.good_pct if grid else 0.0,
                fair_pct=grid.fair_pct if grid else 0.0,
                dead_pct=grid.dead_pct if grid else 0.0,
                thresholds=(
                    Thresholds(
                        good_dbm=grid.good_threshold_dbm,
                        dead_dbm=grid.dead_threshold_dbm,
                    )
                    if grid
                    else None
                ),
                access_point_count=ap_counts.get(floor.id, 0),
            )
        )
    return summaries
