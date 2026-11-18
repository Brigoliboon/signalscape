import uuid
from datetime import datetime

from sqlalchemy import (
    REAL,
    Boolean,
    CheckConstraint,
    DateTime,
    Double,
    ForeignKey,
    Index,
    Integer,
    SmallInteger,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB, MACADDR, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class AccessPointEstimate(Base):
    """Estimated position of one access point (FR-14, FR-23 to FR-25).

    ``confidence``, ``low_confidence`` and ``spread_m`` are null on rows stored
    before v1.1 (method ``weighted_centroid``); readers treat those as low
    confidence until the survey is processed again.
    """

    __tablename__ = "access_point_estimates"
    __table_args__ = (
        UniqueConstraint("survey_id", "bssid", name="uq_access_point_estimates_bssid"),
        Index("ix_access_point_estimates_survey_floor", "survey_id", "floor_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        server_default=text("gen_random_uuid()"),
    )
    survey_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("surveys.id", ondelete="CASCADE"),
        nullable=False,
    )
    floor_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("floors.id", ondelete="CASCADE"),
        nullable=False,
    )
    bssid: Mapped[str] = mapped_column(MACADDR, nullable=False)
    ssid: Mapped[str] = mapped_column(Text, nullable=False, server_default="")
    frequency_mhz: Mapped[int] = mapped_column(Integer, nullable=False)
    lat: Mapped[float] = mapped_column(Double, nullable=False)
    lng: Mapped[float] = mapped_column(Double, nullable=False)
    method: Mapped[str] = mapped_column(Text, nullable=False)
    reading_count: Mapped[int] = mapped_column(Integer, nullable=False)
    max_rssi_dbm: Mapped[int] = mapped_column(SmallInteger, nullable=False)
    confidence: Mapped[float | None] = mapped_column(REAL, nullable=True)
    low_confidence: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    spread_m: Mapped[float | None] = mapped_column(REAL, nullable=True)
    computed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class CoverageGrid(Base):
    """Cached interpolation result for one floor and one network, or the strongest
    signal of any network when ``bssid`` is null (FR-13, FR-15, FR-19).

    Beyond the design table, each grid also stores the thresholds it was classified
    with and the raw and cleaned reading counts it was built from, so reading it
    back needs no recomputation.
    """

    __tablename__ = "coverage_grids"
    __table_args__ = (
        UniqueConstraint(
            "survey_id",
            "floor_id",
            "bssid",
            name="uq_coverage_grids_survey_floor_bssid",
            postgresql_nulls_not_distinct=True,
        ),
        CheckConstraint("cols > 0 AND rows > 0", name="ck_coverage_grids_size"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        server_default=text("gen_random_uuid()"),
    )
    survey_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("surveys.id", ondelete="CASCADE"),
        nullable=False,
    )
    floor_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("floors.id", ondelete="CASCADE"),
        nullable=False,
    )
    bssid: Mapped[str | None] = mapped_column(MACADDR, nullable=True)
    method: Mapped[str] = mapped_column(Text, nullable=False)
    cell_size_m: Mapped[float] = mapped_column(
        REAL, nullable=False, server_default=text("1.0")
    )
    origin_lat: Mapped[float] = mapped_column(Double, nullable=False)
    origin_lng: Mapped[float] = mapped_column(Double, nullable=False)
    cols: Mapped[int] = mapped_column(SmallInteger, nullable=False)
    rows: Mapped[int] = mapped_column(SmallInteger, nullable=False)
    # Row-major list of dBm values, null where there is no data.
    values: Mapped[list[float | None]] = mapped_column(JSONB, nullable=False)
    # Per-cell confidence 0..1 in the same layout; null on grids stored before it
    # existed, which readers treat as 1.
    confidence: Mapped[list[float | None] | None] = mapped_column(JSONB, nullable=True)
    good_pct: Mapped[float] = mapped_column(REAL, nullable=False)
    fair_pct: Mapped[float] = mapped_column(REAL, nullable=False)
    dead_pct: Mapped[float] = mapped_column(REAL, nullable=False)
    good_threshold_dbm: Mapped[int] = mapped_column(SmallInteger, nullable=False)
    dead_threshold_dbm: Mapped[int] = mapped_column(SmallInteger, nullable=False)
    raw_reading_count: Mapped[int] = mapped_column(Integer, nullable=False)
    cleaned_reading_count: Mapped[int] = mapped_column(Integer, nullable=False)
    computed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
