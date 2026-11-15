"""Access point estimates and coverage grids.

Revision ID: 0005
Revises: 0004
Create Date: 2026-11-16
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0005"
down_revision: Union[str, Sequence[str], None] = "0004"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _uuid_pk() -> sa.Column:
    return sa.Column(
        "id",
        postgresql.UUID(as_uuid=True),
        server_default=sa.text("gen_random_uuid()"),
        nullable=False,
    )


def _computed_at() -> sa.Column:
    return sa.Column(
        "computed_at",
        sa.DateTime(timezone=True),
        server_default=sa.text("now()"),
        nullable=False,
    )


def upgrade() -> None:
    op.create_table(
        "access_point_estimates",
        _uuid_pk(),
        sa.Column("survey_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("floor_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("bssid", postgresql.MACADDR(), nullable=False),
        sa.Column("ssid", sa.Text(), server_default="", nullable=False),
        sa.Column("frequency_mhz", sa.Integer(), nullable=False),
        sa.Column("lat", sa.Double(), nullable=False),
        sa.Column("lng", sa.Double(), nullable=False),
        sa.Column("method", sa.Text(), nullable=False),
        sa.Column("reading_count", sa.Integer(), nullable=False),
        sa.Column("max_rssi_dbm", sa.SmallInteger(), nullable=False),
        _computed_at(),
        sa.ForeignKeyConstraint(["survey_id"], ["surveys.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["floor_id"], ["floors.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "survey_id", "bssid", name="uq_access_point_estimates_bssid"
        ),
    )
    op.create_index(
        "ix_access_point_estimates_survey_floor",
        "access_point_estimates",
        ["survey_id", "floor_id"],
    )

    op.create_table(
        "coverage_grids",
        _uuid_pk(),
        sa.Column("survey_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("floor_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("bssid", postgresql.MACADDR(), nullable=True),
        sa.Column("method", sa.Text(), nullable=False),
        sa.Column(
            "cell_size_m", sa.REAL(), server_default=sa.text("1.0"), nullable=False
        ),
        sa.Column("origin_lat", sa.Double(), nullable=False),
        sa.Column("origin_lng", sa.Double(), nullable=False),
        sa.Column("cols", sa.SmallInteger(), nullable=False),
        sa.Column("rows", sa.SmallInteger(), nullable=False),
        sa.Column("values", postgresql.JSONB(), nullable=False),
        sa.Column("good_pct", sa.REAL(), nullable=False),
        sa.Column("fair_pct", sa.REAL(), nullable=False),
        sa.Column("dead_pct", sa.REAL(), nullable=False),
        sa.Column("good_threshold_dbm", sa.SmallInteger(), nullable=False),
        sa.Column("dead_threshold_dbm", sa.SmallInteger(), nullable=False),
        sa.Column("raw_reading_count", sa.Integer(), nullable=False),
        sa.Column("cleaned_reading_count", sa.Integer(), nullable=False),
        _computed_at(),
        sa.CheckConstraint("cols > 0 AND rows > 0", name="ck_coverage_grids_size"),
        sa.ForeignKeyConstraint(["survey_id"], ["surveys.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["floor_id"], ["floors.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "survey_id",
            "floor_id",
            "bssid",
            name="uq_coverage_grids_survey_floor_bssid",
            postgresql_nulls_not_distinct=True,
        ),
    )


def downgrade() -> None:
    op.drop_table("coverage_grids")
    op.drop_index(
        "ix_access_point_estimates_survey_floor", table_name="access_point_estimates"
    )
    op.drop_table("access_point_estimates")
