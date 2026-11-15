"""The walk of a survey: where the surveyor was, from scans and checkpoints."""

import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.survey import Checkpoint, ScanReading, Survey
from app.schemas.result import TrailFloor, TrailPoint, TrailRead
from app.services.results import floors_of

# A floor never returns more points than this; longer walks are thinned evenly.
MAX_POINTS_PER_FLOOR = 5000


def _thin(items: list, limit: int) -> list:
    """At most ``limit`` items, evenly spread, always keeping the first and last."""
    if len(items) <= limit:
        return items
    last = len(items) - 1
    keep = sorted({round(i * last / (limit - 1)) for i in range(limit)})
    return [items[i] for i in keep]


def trail_read(db: Session, survey: Survey) -> TrailRead:
    floors = floors_of(db, survey)
    # One row per scan: every network seen in a scan shares the place and time.
    scans = db.execute(
        select(
            ScanReading.floor_id,
            ScanReading.lat,
            ScanReading.lng,
            ScanReading.scanned_at,
        )
        .where(ScanReading.survey_id == survey.id)
        .distinct()
    ).all()
    marks = db.execute(
        select(
            Checkpoint.floor_id,
            Checkpoint.lat,
            Checkpoint.lng,
            Checkpoint.recorded_at,
        ).where(Checkpoint.survey_id == survey.id)
    ).all()
    rows: list[tuple[datetime, uuid.UUID, float, float, str]] = [
        (r.scanned_at, r.floor_id, r.lat, r.lng, "reading") for r in scans
    ] + [(r.recorded_at, r.floor_id, r.lat, r.lng, "checkpoint") for r in marks]
    # Time first, then a scan before a checkpoint taken at the same moment.
    rows.sort(key=lambda r: (r[0], r[4] == "checkpoint", r[2], r[3]))

    def point(row: tuple, kind: str | None = None) -> TrailPoint:
        at, floor_id, lat, lng, row_kind = row
        return TrailPoint(
            floor_id=floor_id,
            floor_level=floors[floor_id].level,
            lat=lat,
            lng=lng,
            at=at,
            kind=kind or row_kind,
        )

    if not rows:
        return TrailRead(survey_id=survey.id, start=None, end=None, floors=[])
    start_row = (
        survey.started_at,
        rows[0][1],
        survey.origin_lat,
        survey.origin_lng,
        "start",
    )
    start = point(start_row)
    by_floor: dict[uuid.UUID, list[TrailPoint]] = {start.floor_id: [start]}
    for row in rows:
        by_floor.setdefault(row[1], []).append(point(row))
    ordered = sorted(by_floor, key=lambda fid: floors[fid].level)
    return TrailRead(
        survey_id=survey.id,
        start=start,
        end=point(rows[-1]),
        floors=[
            TrailFloor(
                floor_id=fid,
                floor_level=floors[fid].level,
                points=_thin(by_floor[fid], MAX_POINTS_PER_FLOOR),
            )
            for fid in ordered
        ],
    )
