import uuid
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from fastapi.responses import JSONResponse
from sqlalchemy import ColumnElement, Text, cast, func, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_builder
from app.api.pagination import (
    Page,
    PageParams,
    paginate,
    paginate_rows,
    pagination_params,
    sort_param,
)
from app.db.session import get_db
from app.models.result import AccessPointEstimate, CoverageGrid
from app.models.survey import ScanReading
from app.models.user import User
from app.schemas.result import (
    AccessPointRead,
    CoverageRead,
    NetworkRead,
    ProcessResult,
    SurveySummary,
    TrailRead,
)
from app.schemas.survey import Bssid
from app.services.export import geojson, readings_csv
from app.services.results import (
    coverage_read,
    floors_of,
    require_processed,
    run_processing,
    stored_summary,
)
from app.services.surveys import get_survey_or_404
from app.services.trail import trail_read

router = APIRouter(prefix="/api/surveys", tags=["results"])

_reading_count = func.count(ScanReading.id)
network_sort = sort_param(
    {
        "reading_count": _reading_count,
        "max_rssi_dbm": func.max(ScanReading.rssi_dbm),
        "ssid": ScanReading.ssid,
        "bssid": ScanReading.bssid,
    },
    default="-reading_count",
    tie_breaker=ScanReading.bssid,
)
access_point_sort = sort_param(
    {
        "max_rssi_dbm": AccessPointEstimate.max_rssi_dbm,
        "ssid": AccessPointEstimate.ssid,
        "bssid": AccessPointEstimate.bssid,
        "reading_count": AccessPointEstimate.reading_count,
        "confidence": AccessPointEstimate.confidence,
    },
    default="-max_rssi_dbm",
    tie_breaker=AccessPointEstimate.id,
)


def _escape_like(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _not_found() -> HTTPException:
    return HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not found")


@router.post("/{survey_id}/process", response_model=ProcessResult)
def process_survey(
    survey_id: uuid.UUID,
    preview: Annotated[
        bool,
        Query(
            description="Compute the strongest-signal heatmap and access points from "
            "the readings synced so far, return them and save nothing"
        ),
    ] = False,
    floor_id: Annotated[
        uuid.UUID | None, Query(description="Only this floor (handy for a preview)")
    ] = None,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> ProcessResult:
    """Clean the readings, build the coverage grids and estimate access points.

    A full run needs a completed (or already processed) survey, replaces any earlier
    results and sets the status to ``processed``. A preview works in any status and
    changes nothing.
    """
    survey = get_survey_or_404(db, user, survey_id)
    return run_processing(db, survey, preview=preview, floor_id=floor_id)


@router.get("/{survey_id}/coverage", response_model=CoverageRead)
def get_coverage(
    survey_id: uuid.UUID,
    floor_id: uuid.UUID,
    bssid: Bssid | None = None,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> CoverageRead:
    """The grid of one floor: the strongest signal of any network, or one BSSID."""
    survey = get_survey_or_404(db, user, survey_id)
    require_processed(survey)
    floor = floors_of(db, survey).get(floor_id)
    if floor is None:
        raise _not_found()
    stmt = select(CoverageGrid).where(
        CoverageGrid.survey_id == survey.id, CoverageGrid.floor_id == floor.id
    )
    stmt = stmt.where(
        CoverageGrid.bssid.is_(None) if bssid is None else CoverageGrid.bssid == bssid
    )
    grid = db.scalar(stmt)
    if grid is None:
        raise _not_found()
    return coverage_read(grid, floor)


@router.get("/{survey_id}/access-points", response_model=Page[AccessPointRead])
def list_access_points(
    survey_id: uuid.UUID,
    floor_id: uuid.UUID | None = None,
    ssid: Annotated[str | None, Query(description="Contains, ignoring case")] = None,
    bssid: Bssid | None = None,
    page: PageParams = Depends(pagination_params),
    order_by: list[ColumnElement] = Depends(access_point_sort),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    survey = get_survey_or_404(db, user, survey_id)
    require_processed(survey)
    stmt = select(AccessPointEstimate).where(AccessPointEstimate.survey_id == survey.id)
    if floor_id is not None:
        stmt = stmt.where(AccessPointEstimate.floor_id == floor_id)
    if ssid and ssid.strip():
        pattern = f"%{_escape_like(ssid.strip())}%"
        stmt = stmt.where(AccessPointEstimate.ssid.ilike(pattern, escape="\\"))
    if bssid is not None:
        stmt = stmt.where(AccessPointEstimate.bssid == bssid)
    result = paginate(db, stmt, page, order_by)
    floors = floors_of(db, survey)
    result["items"] = [
        AccessPointRead(
            id=ap.id,
            survey_id=ap.survey_id,
            floor_id=ap.floor_id,
            floor_level=floors[ap.floor_id].level,
            bssid=str(ap.bssid),
            ssid=ap.ssid,
            frequency_mhz=ap.frequency_mhz,
            lat=ap.lat,
            lng=ap.lng,
            method=ap.method,
            reading_count=ap.reading_count,
            max_rssi_dbm=ap.max_rssi_dbm,
            confidence=ap.confidence,
            low_confidence=ap.low_confidence,
            spread_m=ap.spread_m,
            computed_at=ap.computed_at,
        )
        for ap in result["items"]
    ]
    return result


@router.get("/{survey_id}/summary", response_model=SurveySummary)
def get_summary(
    survey_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> SurveySummary:
    """Per floor: readings (raw and cleaned), area covered and the share of good,
    fair and dead cells (FR-19)."""
    survey = get_survey_or_404(db, user, survey_id)
    require_processed(survey)
    return SurveySummary(
        survey_id=survey.id,
        status=survey.status.value,
        processed_at=survey.processed_at,
        floors=stored_summary(db, survey),
    )


@router.get("/{survey_id}/networks", response_model=Page[NetworkRead])
def list_networks(
    survey_id: uuid.UUID,
    floor_id: uuid.UUID | None = None,
    q: Annotated[str | None, Query(description="Search SSID or BSSID")] = None,
    page: PageParams = Depends(pagination_params),
    order_by: list[ColumnElement] = Depends(network_sort),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Distinct SSID and BSSID pairs seen in the survey, with reading counts. Works
    on the raw readings, so it is available before processing (FR-17)."""
    survey = get_survey_or_404(db, user, survey_id)
    stmt = (
        select(
            ScanReading.ssid,
            cast(ScanReading.bssid, Text).label("bssid"),
            _reading_count.label("reading_count"),
            func.max(ScanReading.rssi_dbm).label("max_rssi_dbm"),
        )
        .where(ScanReading.survey_id == survey.id)
        .group_by(ScanReading.ssid, ScanReading.bssid)
    )
    if floor_id is not None:
        stmt = stmt.where(ScanReading.floor_id == floor_id)
    if q and q.strip():
        pattern = f"%{_escape_like(q.strip())}%"
        stmt = stmt.where(
            ScanReading.ssid.ilike(pattern, escape="\\")
            | cast(ScanReading.bssid, Text).ilike(pattern, escape="\\")
        )
    return paginate_rows(db, stmt, page, [*order_by, ScanReading.ssid.asc()])


@router.get("/{survey_id}/trail", response_model=TrailRead)
def get_trail(
    survey_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> TrailRead:
    """The walk, floor by floor, in time order, from the scan positions and the
    checkpoints, with the start and the last place. Works on the raw data, so it
    is available before processing."""
    survey = get_survey_or_404(db, user, survey_id)
    return trail_read(db, survey)


@router.get("/{survey_id}/geojson")
def get_geojson(
    survey_id: uuid.UUID,
    floor_level: Annotated[int | None, Query(description="Only this floor")] = None,
    bssid: Annotated[
        Bssid | None, Query(description="One network instead of the strongest signal")
    ] = None,
    include: Annotated[
        list[Literal["cells", "access_points", "readings"]] | None,
        Query(description="Repeat to combine; default is cells and access_points"),
    ] = None,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> JSONResponse:
    """GeoJSON FeatureCollection. Every feature has a ``floor_level`` property so a
    map can show one layer per floor. Coverage cells are polygons, access points and
    readings are points. Cells and access points need a processed survey."""
    survey = get_survey_or_404(db, user, survey_id)
    wanted = include or ["cells", "access_points"]
    if {"cells", "access_points"} & set(wanted):
        require_processed(survey)
    content = geojson(db, survey, include=wanted, floor_level=floor_level, bssid=bssid)
    return JSONResponse(content, media_type="application/geo+json")


@router.get("/{survey_id}/export.csv")
def export_csv(
    survey_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Response:
    """All readings of the survey as CSV (FR-21)."""
    survey = get_survey_or_404(db, user, survey_id)
    return Response(
        readings_csv(db, survey),
        media_type="text/csv",
        headers={
            "Content-Disposition": f'attachment; filename="survey-{survey.id}.csv"'
        },
    )
