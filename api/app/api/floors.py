import uuid
from pathlib import Path

from fastapi import (
    APIRouter,
    Depends,
    HTTPException,
    Response,
    UploadFile,
    status,
)
from fastapi.responses import FileResponse
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_uploads_dir, require_builder
from app.db.session import get_db
from app.models.building import Floor
from app.models.user import User
from app.schemas.building import FloorRead, FloorUpdate
from app.services.buildings import (
    MAX_PLAN_BYTES,
    delete_plan_files,
    detect_plan_extension,
    get_floor_or_404,
    not_found,
    plan_media_type,
    write_plan_file,
)

router = APIRouter(prefix="/api/floors", tags=["floors"])


@router.patch("/{floor_id}", response_model=FloorRead)
def update_floor(
    floor_id: uuid.UUID,
    payload: FloorUpdate,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
) -> Floor:
    floor = get_floor_or_404(db, user, floor_id)
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(floor, field, value)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="This building already has a floor at that level",
        ) from None
    db.refresh(floor)
    return floor


@router.delete("/{floor_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_floor(
    floor_id: uuid.UUID,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
    uploads_dir: Path = Depends(get_uploads_dir),
) -> Response:
    floor = get_floor_or_404(db, user, floor_id)
    plan_file = floor.plan_image_path
    db.delete(floor)
    db.commit()
    delete_plan_files(uploads_dir, [plan_file])
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.put("/{floor_id}/plan", response_model=FloorRead)
def upload_plan(
    floor_id: uuid.UUID,
    file: UploadFile,
    user: User = Depends(require_builder),
    db: Session = Depends(get_db),
    uploads_dir: Path = Depends(get_uploads_dir),
) -> Floor:
    """Upload or replace the floor plan. PNG or JPEG, at most 5 MB."""
    floor = get_floor_or_404(db, user, floor_id)
    data = file.file.read(MAX_PLAN_BYTES + 1)
    if len(data) > MAX_PLAN_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_CONTENT_TOO_LARGE,
            detail=f"Floor plan must be at most {MAX_PLAN_BYTES // (1024 * 1024)} MB",
        )
    ext = detect_plan_extension(data)
    if ext is None:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail="Floor plan must be a PNG or JPEG image",
        )
    old_file = floor.plan_image_path
    new_file = write_plan_file(uploads_dir, floor.id, ext, data)
    floor.plan_image_path = new_file
    db.commit()
    db.refresh(floor)
    if old_file and old_file != new_file:
        delete_plan_files(uploads_dir, [old_file])
    return floor


@router.get("/{floor_id}/plan")
def get_plan(
    floor_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    uploads_dir: Path = Depends(get_uploads_dir),
) -> FileResponse:
    floor = get_floor_or_404(db, user, floor_id)
    if floor.plan_image_path is None:
        raise not_found()
    path = uploads_dir / Path(floor.plan_image_path).name
    if not path.is_file():
        raise not_found()
    return FileResponse(path, media_type=plan_media_type(path.name))
