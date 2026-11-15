"""Surveys, scan readings, checkpoints and survey shares.

Revision ID: 0004
Revises: 0003
Create Date: 2026-11-15
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0004"
down_revision: Union[str, Sequence[str], None] = "0003"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _uuid_pk() -> sa.Column:
    return sa.Column(
        "id",
        postgresql.UUID(as_uuid=True),
        server_default=sa.text("gen_random_uuid()"),
        nullable=False,
    )


def _created_at() -> sa.Column:
    return sa.Column(
        "created_at",
        sa.DateTime(timezone=True),
        server_default=sa.text("now()"),
        nullable=False,
    )


def upgrade() -> None:
    op.create_table(
        "surveys",
        _uuid_pk(),
        sa.Column("building_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("surveyor_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column(
            "status",
            sa.Enum("active", "paused", "completed", "processed", name="survey_status"),
            server_default="active",
            nullable=False,
        ),
        sa.Column(
            "started_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("device_model", sa.Text(), nullable=True),
        sa.Column(
            "has_barometer",
            sa.Boolean(),
            server_default=sa.text("false"),
            nullable=False,
        ),
        sa.Column("origin_lat", sa.Double(), nullable=False),
        sa.Column("origin_lng", sa.Double(), nullable=False),
        sa.Column("origin_accuracy_m", sa.REAL(), nullable=False),
        sa.Column(
            "step_length_m",
            sa.Numeric(3, 2),
            server_default=sa.text("0.7"),
            nullable=False,
        ),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("processed_at", sa.DateTime(timezone=True), nullable=True),
        _created_at(),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "origin_lat BETWEEN -90 AND 90", name="ck_surveys_origin_lat_range"
        ),
        sa.CheckConstraint(
            "origin_lng BETWEEN -180 AND 180", name="ck_surveys_origin_lng_range"
        ),
        sa.CheckConstraint(
            "origin_accuracy_m >= 0 AND origin_accuracy_m <= 10",
            name="ck_surveys_origin_accuracy",
        ),
        sa.CheckConstraint("step_length_m > 0", name="ck_surveys_step_length_positive"),
        sa.ForeignKeyConstraint(["building_id"], ["buildings.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["surveyor_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_surveys_building_id_started_at", "surveys", ["building_id", "started_at"]
    )
    op.create_index("ix_surveys_surveyor_id", "surveys", ["surveyor_id"])

    op.create_table(
        "scan_readings",
        sa.Column("id", sa.BigInteger(), sa.Identity(), nullable=False),
        sa.Column("survey_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("floor_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("client_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("lat", sa.Double(), nullable=False),
        sa.Column("lng", sa.Double(), nullable=False),
        sa.Column("accuracy_m", sa.REAL(), nullable=True),
        sa.Column("bssid", postgresql.MACADDR(), nullable=False),
        sa.Column("ssid", sa.Text(), server_default="", nullable=False),
        sa.Column("rssi_dbm", sa.SmallInteger(), nullable=False),
        sa.Column("frequency_mhz", sa.Integer(), nullable=False),
        sa.Column("scanned_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("lat BETWEEN -90 AND 90", name="ck_scan_readings_lat_range"),
        sa.CheckConstraint(
            "lng BETWEEN -180 AND 180", name="ck_scan_readings_lng_range"
        ),
        sa.CheckConstraint(
            "rssi_dbm BETWEEN -120 AND 0", name="ck_scan_readings_rssi_range"
        ),
        sa.CheckConstraint(
            "accuracy_m IS NULL OR accuracy_m >= 0",
            name="ck_scan_readings_accuracy_positive",
        ),
        sa.ForeignKeyConstraint(["survey_id"], ["surveys.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["floor_id"], ["floors.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("survey_id", "client_id", name="uq_scan_readings_client"),
    )
    op.create_index(
        "ix_scan_readings_survey_floor", "scan_readings", ["survey_id", "floor_id"]
    )
    op.create_index(
        "ix_scan_readings_survey_bssid", "scan_readings", ["survey_id", "bssid"]
    )

    op.create_table(
        "checkpoints",
        _uuid_pk(),
        sa.Column("survey_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("floor_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("client_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("lat", sa.Double(), nullable=False),
        sa.Column("lng", sa.Double(), nullable=False),
        sa.Column("estimated_lat", sa.Double(), nullable=False),
        sa.Column("estimated_lng", sa.Double(), nullable=False),
        sa.Column(
            "source",
            sa.Enum("tap", "gps", name="checkpoint_source"),
            nullable=False,
        ),
        sa.Column("recorded_at", sa.DateTime(timezone=True), nullable=False),
        _created_at(),
        sa.CheckConstraint("lat BETWEEN -90 AND 90", name="ck_checkpoints_lat_range"),
        sa.CheckConstraint("lng BETWEEN -180 AND 180", name="ck_checkpoints_lng_range"),
        sa.CheckConstraint(
            "estimated_lat BETWEEN -90 AND 90", name="ck_checkpoints_est_lat_range"
        ),
        sa.CheckConstraint(
            "estimated_lng BETWEEN -180 AND 180", name="ck_checkpoints_est_lng_range"
        ),
        sa.ForeignKeyConstraint(["survey_id"], ["surveys.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["floor_id"], ["floors.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("survey_id", "client_id", name="uq_checkpoints_client"),
    )
    op.create_index(
        "ix_checkpoints_survey_floor", "checkpoints", ["survey_id", "floor_id"]
    )

    op.create_table(
        "survey_shares",
        sa.Column("survey_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        _created_at(),
        sa.ForeignKeyConstraint(["survey_id"], ["surveys.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("survey_id", "user_id"),
    )
    op.create_index("ix_survey_shares_user_id", "survey_shares", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_survey_shares_user_id", table_name="survey_shares")
    op.drop_table("survey_shares")
    op.drop_index("ix_checkpoints_survey_floor", table_name="checkpoints")
    op.drop_table("checkpoints")
    op.drop_index("ix_scan_readings_survey_bssid", table_name="scan_readings")
    op.drop_index("ix_scan_readings_survey_floor", table_name="scan_readings")
    op.drop_table("scan_readings")
    op.drop_index("ix_surveys_surveyor_id", table_name="surveys")
    op.drop_index("ix_surveys_building_id_started_at", table_name="surveys")
    op.drop_table("surveys")
    bind = op.get_bind()
    sa.Enum(name="checkpoint_source").drop(bind, checkfirst=True)
    sa.Enum(name="survey_status").drop(bind, checkfirst=True)
