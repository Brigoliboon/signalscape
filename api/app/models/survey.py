import enum
import uuid
from datetime import datetime
from decimal import Decimal

from sqlalchemy import (
    REAL,
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    Double,
    Enum,
    ForeignKey,
    Identity,
    Index,
    Integer,
    Numeric,
    SmallInteger,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import MACADDR, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base

DEFAULT_STEP_LENGTH_M = Decimal("0.7")
# The GPS fix that anchors a survey must be at least this good (DESIGN.md section 1).
MAX_ORIGIN_ACCURACY_M = 10


class SurveyStatus(enum.StrEnum):
    ACTIVE = "active"
    PAUSED = "paused"
    COMPLETED = "completed"
    PROCESSED = "processed"


class CheckpointSource(enum.StrEnum):
    TAP = "tap"
    GPS = "gps"


def _enum_values(enum_cls: type[enum.Enum]) -> list[str]:
    return [member.value for member in enum_cls]


def _uuid_pk() -> Mapped[uuid.UUID]:
    return mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        server_default=text("gen_random_uuid()"),
    )


class Survey(Base):
    __tablename__ = "surveys"
    __table_args__ = (
        CheckConstraint(
            "origin_lat BETWEEN -90 AND 90", name="ck_surveys_origin_lat_range"
        ),
        CheckConstraint(
            "origin_lng BETWEEN -180 AND 180", name="ck_surveys_origin_lng_range"
        ),
        CheckConstraint(
            f"origin_accuracy_m >= 0 AND origin_accuracy_m <= {MAX_ORIGIN_ACCURACY_M}",
            name="ck_surveys_origin_accuracy",
        ),
        CheckConstraint("step_length_m > 0", name="ck_surveys_step_length_positive"),
        Index("ix_surveys_building_id_started_at", "building_id", "started_at"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
    building_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("buildings.id", ondelete="CASCADE"),
        nullable=False,
    )
    surveyor_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    status: Mapped[SurveyStatus] = mapped_column(
        Enum(SurveyStatus, name="survey_status", values_callable=_enum_values),
        nullable=False,
        default=SurveyStatus.ACTIVE,
        server_default=SurveyStatus.ACTIVE.value,
    )
    started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    ended_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    device_model: Mapped[str | None] = mapped_column(Text, nullable=True)
    has_barometer: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=text("false")
    )
    origin_lat: Mapped[float] = mapped_column(Double, nullable=False)
    origin_lng: Mapped[float] = mapped_column(Double, nullable=False)
    origin_accuracy_m: Mapped[float] = mapped_column(REAL, nullable=False)
    step_length_m: Mapped[Decimal] = mapped_column(
        Numeric(3, 2),
        nullable=False,
        default=DEFAULT_STEP_LENGTH_M,
        server_default=text("0.7"),
    )
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    processed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class ScanReading(Base):
    __tablename__ = "scan_readings"
    __table_args__ = (
        UniqueConstraint("survey_id", "client_id", name="uq_scan_readings_client"),
        CheckConstraint("lat BETWEEN -90 AND 90", name="ck_scan_readings_lat_range"),
        CheckConstraint("lng BETWEEN -180 AND 180", name="ck_scan_readings_lng_range"),
        CheckConstraint(
            "rssi_dbm BETWEEN -120 AND 0", name="ck_scan_readings_rssi_range"
        ),
        CheckConstraint(
            "accuracy_m IS NULL OR accuracy_m >= 0",
            name="ck_scan_readings_accuracy_positive",
        ),
        Index("ix_scan_readings_survey_floor", "survey_id", "floor_id"),
        Index("ix_scan_readings_survey_bssid", "survey_id", "bssid"),
    )

    id: Mapped[int] = mapped_column(BigInteger, Identity(), primary_key=True)
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
    # Generated on the phone. Unique per survey so offline re-uploads are idempotent.
    client_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    lat: Mapped[float] = mapped_column(Double, nullable=False)
    lng: Mapped[float] = mapped_column(Double, nullable=False)
    accuracy_m: Mapped[float | None] = mapped_column(REAL, nullable=True)
    bssid: Mapped[str] = mapped_column(MACADDR, nullable=False)
    ssid: Mapped[str] = mapped_column(Text, nullable=False, server_default="")
    rssi_dbm: Mapped[int] = mapped_column(SmallInteger, nullable=False)
    frequency_mhz: Mapped[int] = mapped_column(Integer, nullable=False)
    scanned_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )


class Checkpoint(Base):
    __tablename__ = "checkpoints"
    __table_args__ = (
        UniqueConstraint("survey_id", "client_id", name="uq_checkpoints_client"),
        CheckConstraint("lat BETWEEN -90 AND 90", name="ck_checkpoints_lat_range"),
        CheckConstraint("lng BETWEEN -180 AND 180", name="ck_checkpoints_lng_range"),
        CheckConstraint(
            "estimated_lat BETWEEN -90 AND 90", name="ck_checkpoints_est_lat_range"
        ),
        CheckConstraint(
            "estimated_lng BETWEEN -180 AND 180", name="ck_checkpoints_est_lng_range"
        ),
        Index("ix_checkpoints_survey_floor", "survey_id", "floor_id"),
    )

    id: Mapped[uuid.UUID] = _uuid_pk()
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
    client_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    # True position (tapped or from a good GPS fix) and the dead-reckoning estimate
    # at the same moment, so drift can be measured.
    lat: Mapped[float] = mapped_column(Double, nullable=False)
    lng: Mapped[float] = mapped_column(Double, nullable=False)
    estimated_lat: Mapped[float] = mapped_column(Double, nullable=False)
    estimated_lng: Mapped[float] = mapped_column(Double, nullable=False)
    source: Mapped[CheckpointSource] = mapped_column(
        Enum(CheckpointSource, name="checkpoint_source", values_callable=_enum_values),
        nullable=False,
    )
    recorded_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class SurveyShare(Base):
    """Gives a Viewer read access to one survey."""

    __tablename__ = "survey_shares"

    survey_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("surveys.id", ondelete="CASCADE"),
        primary_key=True,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
        index=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
