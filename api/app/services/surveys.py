"""Access rules, the status state machine and batch inserts for surveys."""

import uuid
from collections.abc import Iterable, Sequence
from datetime import UTC, datetime

from fastapi import HTTPException, status
from sqlalchemy import Select, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.orm import Session

from app.models.building import Floor
from app.models.survey import (
    Checkpoint,
    ScanReading,
    Survey,
    SurveyShare,
    SurveyStatus,
)
from app.models.user import User, UserRole
from app.schemas.survey import CheckpointIn, ReadingIn
from app.services.buildings import not_found

# Allowed changes through PATCH. ``processed`` is only reached by processing and
# ``completed`` is final, so neither has a way out here.
TRANSITIONS: dict[SurveyStatus, set[SurveyStatus]] = {
    SurveyStatus.ACTIVE: {SurveyStatus.PAUSED, SurveyStatus.COMPLETED},
    SurveyStatus.PAUSED: {SurveyStatus.ACTIVE, SurveyStatus.COMPLETED},
    SurveyStatus.COMPLETED: set(),
    SurveyStatus.PROCESSED: set(),
}

# Readings and checkpoints can only be added while the survey is open.
OPEN_STATUSES = {SurveyStatus.ACTIVE, SurveyStatus.PAUSED}


def visible_surveys(user: User) -> Select[tuple[Survey]]:
    """Surveys the user may see: all for admins, their own for surveyors and the
    ones shared with them for viewers."""
    stmt = select(Survey)
    if user.role == UserRole.ADMIN:
        return stmt
    if user.role == UserRole.SURVEYOR:
        return stmt.where(Survey.surveyor_id == user.id)
    shared = select(SurveyShare.survey_id).where(SurveyShare.user_id == user.id)
    return stmt.where(Survey.id.in_(shared))


def get_survey_or_404(db: Session, user: User, survey_id: uuid.UUID) -> Survey:
    survey = db.scalar(visible_surveys(user).where(Survey.id == survey_id))
    if survey is None:
        raise not_found()
    return survey


def apply_status_change(survey: Survey, new_status: SurveyStatus) -> None:
    """Move ``survey`` to ``new_status`` or raise 409 if that is not allowed.

    Asking for the status the survey already has changes nothing, so a client that
    lost the reply can safely repeat the request.
    """
    if new_status == survey.status:
        return
    if new_status not in TRANSITIONS[survey.status]:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"A {survey.status.value} survey cannot become {new_status.value}",
        )
    survey.status = new_status
    if new_status == SurveyStatus.COMPLETED:
        survey.ended_at = datetime.now(UTC)


def require_open(survey: Survey) -> None:
    if survey.status not in OPEN_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"This survey is {survey.status.value}; it no longer accepts data",
        )


def check_floors(db: Session, survey: Survey, floor_ids: Iterable[uuid.UUID]) -> None:
    """Every floor must belong to the survey's building, else 422."""
    wanted = set(floor_ids)
    found = set(
        db.scalars(
            select(Floor.id).where(
                Floor.building_id == survey.building_id, Floor.id.in_(wanted)
            )
        )
    )
    unknown = sorted(str(floor_id) for floor_id in wanted - found)
    if unknown:
        raise HTTPException(
            status_code=422,
            detail="Floors not in this survey's building: " + ", ".join(unknown),
        )


def insert_readings(
    db: Session, survey: Survey, readings: Sequence[ReadingIn]
) -> tuple[int, int]:
    """Store a batch, skipping client ids that already exist. Returns
    ``(inserted, skipped)``."""
    rows = [{"survey_id": survey.id, **item.model_dump()} for item in readings]
    stmt = (
        pg_insert(ScanReading)
        .values(rows)
        .on_conflict_do_nothing(index_elements=["survey_id", "client_id"])
        .returning(ScanReading.id)
    )
    inserted = len(db.execute(stmt).all())
    db.commit()
    return inserted, len(rows) - inserted


def insert_checkpoints(
    db: Session, survey: Survey, checkpoints: Sequence[CheckpointIn]
) -> tuple[int, int]:
    rows = [{"survey_id": survey.id, **item.model_dump()} for item in checkpoints]
    stmt = (
        pg_insert(Checkpoint)
        .values(rows)
        .on_conflict_do_nothing(index_elements=["survey_id", "client_id"])
        .returning(Checkpoint.id)
    )
    inserted = len(db.execute(stmt).all())
    db.commit()
    return inserted, len(rows) - inserted


def find_viewer_by_email(db: Session, email: str) -> User | None:
    return db.scalar(
        select(User).where(
            func.lower(User.email) == email.strip().lower(),
            User.role == UserRole.VIEWER,
            User.is_active.is_(True),
        )
    )
