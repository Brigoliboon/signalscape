"""Campus or site grouping (FR-33).

A site groups buildings and optionally describes the outdoor area between them
as a polygon of latitude/longitude points. Readings whose position falls in
that polygon are consolidated as one outdoor area (FR-35).
"""

import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import (
    Column,
    DateTime,
    ForeignKey,
    Table,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base

if TYPE_CHECKING:
    from app.models.building import Building

site_buildings = Table(
    "site_buildings",
    Base.metadata,
    Column(
        "site_id",
        UUID(as_uuid=True),
        ForeignKey("sites.id", ondelete="CASCADE"),
        primary_key=True,
    ),
    Column(
        "building_id",
        UUID(as_uuid=True),
        ForeignKey("buildings.id", ondelete="CASCADE"),
        primary_key=True,
    ),
)


class Site(Base):
    __tablename__ = "sites"
    __table_args__ = (UniqueConstraint("owner_id", "name", name="uq_sites_owner_name"),)

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        server_default=text("gen_random_uuid()"),
    )
    owner_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    name: Mapped[str] = mapped_column(Text, nullable=False)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Closed polygon as [{"lat": .., "lng": ..}, ...]; null when there is none.
    outdoor_area: Mapped[list[dict] | None] = mapped_column(JSONB, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )

    buildings: Mapped[list["Building"]] = relationship(
        secondary=site_buildings,
        order_by="Building.name",
        passive_deletes=True,
    )

    @property
    def building_ids(self) -> list[uuid.UUID]:
        return [building.id for building in self.buildings]
