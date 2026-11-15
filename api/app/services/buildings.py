"""Access rules and floor plan file handling for buildings and floors."""

import uuid
from collections.abc import Iterable
from pathlib import Path

from fastapi import HTTPException, status
from sqlalchemy import Select, false, select
from sqlalchemy.orm import Session

from app.models.building import Building, Floor
from app.models.user import User, UserRole

MAX_PLAN_BYTES = 5 * 1024 * 1024

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
JPEG_MAGIC = b"\xff\xd8\xff"

PLAN_TYPES = {".png": "image/png", ".jpg": "image/jpeg"}


def not_found() -> HTTPException:
    return HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not found")


def visible_buildings(user: User) -> Select[tuple[Building]]:
    """Buildings the user may see: all for admins, their own for surveyors and
    none for viewers (viewers reach data through survey shares instead)."""
    stmt = select(Building)
    if user.role == UserRole.ADMIN:
        return stmt
    if user.role == UserRole.SURVEYOR:
        return stmt.where(Building.owner_id == user.id)
    return stmt.where(false())


def get_building_or_404(db: Session, user: User, building_id: uuid.UUID) -> Building:
    building = db.scalar(visible_buildings(user).where(Building.id == building_id))
    if building is None:
        raise not_found()
    return building


def get_floor_or_404(db: Session, user: User, floor_id: uuid.UUID) -> Floor:
    visible = visible_buildings(user).with_only_columns(Building.id).scalar_subquery()
    floor = db.scalar(
        select(Floor).where(Floor.id == floor_id, Floor.building_id.in_(visible))
    )
    if floor is None:
        raise not_found()
    return floor


# --- floor plan files -------------------------------------------------------


def detect_plan_extension(data: bytes) -> str | None:
    """Return '.png' or '.jpg' from the file's magic bytes, or None."""
    if data.startswith(PNG_MAGIC):
        return ".png"
    if data.startswith(JPEG_MAGIC):
        return ".jpg"
    return None


def plan_media_type(filename: str) -> str:
    return PLAN_TYPES.get(Path(filename).suffix, "application/octet-stream")


def write_plan_file(
    uploads_dir: Path, floor_id: uuid.UUID, ext: str, data: bytes
) -> str:
    """Save the image as ``<floor id><ext>`` and return the file name."""
    uploads_dir.mkdir(parents=True, exist_ok=True)
    filename = f"{floor_id}{ext}"
    (uploads_dir / filename).write_bytes(data)
    return filename


def delete_plan_files(uploads_dir: Path, filenames: Iterable[str | None]) -> None:
    for filename in filenames:
        if filename:
            # Only the name is used, so a bad stored value cannot leave the folder.
            (uploads_dir / Path(filename).name).unlink(missing_ok=True)


def plan_files_for_buildings(
    db: Session, building_ids: Iterable[uuid.UUID]
) -> list[str]:
    rows = db.scalars(
        select(Floor.plan_image_path).where(
            Floor.building_id.in_(list(building_ids)),
            Floor.plan_image_path.is_not(None),
        )
    )
    return list(rows)


def plan_files_for_owner(db: Session, owner_id: uuid.UUID) -> list[str]:
    """Plan file names for every floor in the user's buildings (account deletion)."""
    ids = db.scalars(select(Building.id).where(Building.owner_id == owner_id))
    return plan_files_for_buildings(db, ids.all())
