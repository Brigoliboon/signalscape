"""Access rules for sites (FR-33)."""

import uuid

from fastapi import HTTPException, status
from sqlalchemy import Select, false, select
from sqlalchemy.orm import Session

from app.models.building import Building
from app.models.site import Site
from app.models.user import User, UserRole
from app.services.buildings import visible_buildings


def not_found() -> HTTPException:
    return HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not found")


def visible_sites(user: User) -> Select[tuple[Site]]:
    """Sites the user may see: all for admins, their own for surveyors, none for
    viewers (they reach data through survey shares)."""
    stmt = select(Site)
    if user.role == UserRole.ADMIN:
        return stmt
    if user.role == UserRole.SURVEYOR:
        return stmt.where(Site.owner_id == user.id)
    return stmt.where(false())


def get_site_or_404(db: Session, user: User, site_id: uuid.UUID) -> Site:
    site = db.scalar(visible_sites(user).where(Site.id == site_id))
    if site is None:
        raise not_found()
    return site


def buildings_from_ids(db: Session, user: User, ids: list[uuid.UUID]) -> list[Building]:
    """Buildings the user may put in a site, in the order given."""
    visible = visible_buildings(user).where(Building.id.in_(set(ids)))
    found = {building.id: building for building in db.scalars(visible)}
    if len(found) != len(set(ids)):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="One of the buildings was not found",
        )
    return [found[building_id] for building_id in dict.fromkeys(ids)]
