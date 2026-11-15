import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from pydantic import AwareDatetime
from sqlalchemy import ColumnElement, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_builder
from app.api.pagination import (
    Page,
    PageParams,
    paginate,
    pagination_params,
    sort_param,
)
from app.db.session import get_db
from app.models.survey import (
    Checkpoint,
    ScanReading,
    Survey,
    SurveyShare,
    SurveyStatus,
)
from app.models.user import User, UserRole
from app.schemas.survey import (
    BatchResult,
    Bssid,
    CheckpointBatch,
    CheckpointRead,
    ReadingBatch,
    ReadingRead,
    ShareCreate,
    ShareRead,
    SurveyCreate,
    SurveyRead,
    SurveyUpdate,
)
from app.services.buildings import get_building_or_404, not_found
from app.services.surveys import (
    apply_status_change,
    check_floors,
    find_viewer_by_email,
    get_survey_or_404,
    insert_checkpoints,
    insert_readings,
    require_open,
    visible_surveys,
)

router = APIRouter(prefix="/api/surveys", tags=["surveys"])

survey_sort = sort_param(
    {"started_at": Survey.started_at, "status": Survey.status},
    default="-started_at",
    tie_breaker=Survey.id,
)
reading_sort = sort_param(
    {"scanned_at": ScanReading.scanned_at, "rssi_dbm": ScanReading.rssi_dbm},
    default="scanned_at",
    tie_breaker=ScanReading.id,
)
checkpoint_sort = sort_param(
    {"recorded_at": Checkpoint.recorded_at},
    default="recorded_at",
    tie_breaker=Checkpoint.id,
)
share_sort = sort_param(
    {"created_at": SurveyShare.created_at},
    default="created_at",
    tie_breaker=SurveyShare.user_id,
)


# --- surveys ----------------------------------------------------------------


@router.get("", response_model=Page[SurveyRead])
def list_surveys(
    building_id: uuid.UUID | None = None,
    status_filter: Annotated[SurveyStatus | None, Query(alias="status")] = None,
    surveyor_id: Annotated[uuid.UUID | None, Query(description="Admin only")] = None,
    from_: Annotated[
        AwareDatetime | None, Query(alias="from", description="Started at or after")
    ] = None,
    to: Annotated[
        AwareDatetime | None, Query(description="Started at or before")
    ] = None,
    page: PageParams = Depends(pagination_params),
    order_by: list[ColumnElement] = Depends(survey_sort),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    if surveyor_id is not None and user.role != UserRole.ADMIN:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only admins can filter by surveyor",
        )
    stmt = visible_surveys(user)
    if building_id is not None:
        stmt = stmt.where(Survey.building_id == building_id)
    if status_filter is not None:
        stmt = stmt.where(Survey.status == status_filter)
    if surveyor_id is not None:
        stmt = stmt.where(Survey.surveyor_id == surveyor_id)
    if from_ is not None:
        stmt = stmt.where(Survey.started_at >= from_)
    if to is not None:
        stmt = stmt.where(Survey.started_at <= to)
    return paginate(db, stmt, page, order_by)


@router.post("", response_model=SurveyRead, status_code=status.HTTP_201_CREATED)
def create_survey(
    payload: SurveyCreate,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> Survey:
    """Start a survey in one of your buildings. Surveyors must have given consent."""
    if user.role == UserRole.SURVEYOR and user.consented_at is None:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Give privacy consent before starting a survey",
        )
    building = get_building_or_404(db, user, payload.building_id)
    data = payload.model_dump(exclude={"building_id"})
    survey = Survey(building_id=building.id, surveyor_id=user.id, **data)
    db.add(survey)
    db.commit()
    db.refresh(survey)
    return survey


@router.get("/{survey_id}", response_model=SurveyRead)
def get_survey(
    survey_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> Survey:
    return get_survey_or_404(db, user, survey_id)


@router.patch("/{survey_id}", response_model=SurveyRead)
def update_survey(
    survey_id: uuid.UUID,
    payload: SurveyUpdate,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> Survey:
    """Pause, resume or complete a survey, or edit its notes.

    active and paused can switch back and forth; either can become completed, which
    is final. Anything else is 409. Repeating the current status is accepted.
    """
    survey = get_survey_or_404(db, user, survey_id)
    changes = payload.model_dump(exclude_unset=True)
    if "status" in changes:
        apply_status_change(survey, payload.status)
    if "notes" in changes:
        survey.notes = payload.notes
    db.commit()
    db.refresh(survey)
    return survey


@router.delete("/{survey_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_survey(
    survey_id: uuid.UUID,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> Response:
    survey = get_survey_or_404(db, user, survey_id)
    db.delete(survey)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --- readings ---------------------------------------------------------------


@router.post("/{survey_id}/readings", response_model=BatchResult)
def upload_readings(
    survey_id: uuid.UUID,
    payload: ReadingBatch,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> BatchResult:
    """Upload up to 1,000 readings. A reading whose ``client_id`` is already stored
    for this survey is skipped, so a batch can be sent again safely."""
    survey = get_survey_or_404(db, user, survey_id)
    require_open(survey)
    check_floors(db, survey, {item.floor_id for item in payload.readings})
    inserted, skipped = insert_readings(db, survey, payload.readings)
    return BatchResult(inserted=inserted, skipped=skipped)


@router.get("/{survey_id}/readings", response_model=Page[ReadingRead])
def list_readings(
    survey_id: uuid.UUID,
    floor_id: uuid.UUID | None = None,
    bssid: Bssid | None = None,
    min_rssi: Annotated[int | None, Query(ge=-120, le=0)] = None,
    page: PageParams = Depends(pagination_params),
    order_by: list[ColumnElement] = Depends(reading_sort),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    survey = get_survey_or_404(db, user, survey_id)
    stmt = select(ScanReading).where(ScanReading.survey_id == survey.id)
    if floor_id is not None:
        stmt = stmt.where(ScanReading.floor_id == floor_id)
    if bssid is not None:
        stmt = stmt.where(ScanReading.bssid == bssid)
    if min_rssi is not None:
        stmt = stmt.where(ScanReading.rssi_dbm >= min_rssi)
    return paginate(db, stmt, page, order_by)


# --- checkpoints ------------------------------------------------------------


@router.post("/{survey_id}/checkpoints", response_model=BatchResult)
def upload_checkpoints(
    survey_id: uuid.UUID,
    payload: CheckpointBatch,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> BatchResult:
    """Upload checkpoints. Idempotent by ``client_id``, like readings."""
    survey = get_survey_or_404(db, user, survey_id)
    require_open(survey)
    check_floors(db, survey, {item.floor_id for item in payload.checkpoints})
    inserted, skipped = insert_checkpoints(db, survey, payload.checkpoints)
    return BatchResult(inserted=inserted, skipped=skipped)


@router.get("/{survey_id}/checkpoints", response_model=Page[CheckpointRead])
def list_checkpoints(
    survey_id: uuid.UUID,
    floor_id: uuid.UUID | None = None,
    page: PageParams = Depends(pagination_params),
    order_by: list[ColumnElement] = Depends(checkpoint_sort),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    survey = get_survey_or_404(db, user, survey_id)
    stmt = select(Checkpoint).where(Checkpoint.survey_id == survey.id)
    if floor_id is not None:
        stmt = stmt.where(Checkpoint.floor_id == floor_id)
    return paginate(db, stmt, page, order_by)


# --- shares (Viewer access) -------------------------------------------------


def _share_read(share: SurveyShare, viewer: User) -> ShareRead:
    return ShareRead(
        survey_id=share.survey_id,
        user_id=share.user_id,
        email=viewer.email,
        name=viewer.name,
        created_at=share.created_at,
    )


@router.get("/{survey_id}/shares", response_model=Page[ShareRead])
def list_shares(
    survey_id: uuid.UUID,
    page: PageParams = Depends(pagination_params),
    order_by: list[ColumnElement] = Depends(share_sort),
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> dict:
    survey = get_survey_or_404(db, user, survey_id)
    stmt = select(SurveyShare).where(SurveyShare.survey_id == survey.id)
    result = paginate(db, stmt, page, order_by)
    viewers = {
        viewer.id: viewer
        for viewer in db.scalars(
            select(User).where(User.id.in_([s.user_id for s in result["items"]]))
        )
    }
    result["items"] = [_share_read(s, viewers[s.user_id]) for s in result["items"]]
    return result


@router.post(
    "/{survey_id}/shares",
    response_model=ShareRead,
    status_code=status.HTTP_201_CREATED,
)
def create_share(
    survey_id: uuid.UUID,
    payload: ShareCreate,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> ShareRead:
    """Let a Viewer read this survey. The email must belong to an active Viewer."""
    survey = get_survey_or_404(db, user, survey_id)
    viewer = find_viewer_by_email(db, payload.email)
    if viewer is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No active viewer account with that email",
        )
    share = SurveyShare(survey_id=survey.id, user_id=viewer.id)
    db.add(share)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="This survey is already shared with that viewer",
        ) from None
    db.refresh(share)
    return _share_read(share, viewer)


@router.delete("/{survey_id}/shares/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_share(
    survey_id: uuid.UUID,
    user_id: uuid.UUID,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> Response:
    survey = get_survey_or_404(db, user, survey_id)
    share = db.get(SurveyShare, (survey.id, user_id))
    if share is None:
        raise not_found()
    db.delete(share)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
