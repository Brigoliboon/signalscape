"""Buildings and floors tables.

Revision ID: 0003
Revises: 0002
Create Date: 2026-11-15
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0003"
down_revision: Union[str, Sequence[str], None] = "0002"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _timestamps() -> list[sa.Column]:
    return [
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
    ]


def upgrade() -> None:
    op.create_table(
        "buildings",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            server_default=sa.text("gen_random_uuid()"),
            nullable=False,
        ),
        sa.Column("owner_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("address", sa.Text(), nullable=True),
        sa.Column("description", sa.Text(), nullable=True),
        *_timestamps(),
        sa.ForeignKeyConstraint(["owner_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("owner_id", "name", name="uq_buildings_owner_name"),
    )
    op.create_index("ix_buildings_owner_id", "buildings", ["owner_id"])

    op.create_table(
        "floors",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            server_default=sa.text("gen_random_uuid()"),
            nullable=False,
        ),
        sa.Column("building_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("level", sa.SmallInteger(), nullable=False),
        sa.Column("label", sa.Text(), nullable=False),
        sa.Column("width_m", sa.Numeric(6, 2), nullable=True),
        sa.Column("length_m", sa.Numeric(6, 2), nullable=True),
        sa.Column(
            "height_m",
            sa.Numeric(4, 2),
            server_default=sa.text("3.0"),
            nullable=False,
        ),
        sa.Column("plan_image_path", sa.Text(), nullable=True),
        *_timestamps(),
        sa.ForeignKeyConstraint(["building_id"], ["buildings.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("building_id", "level", name="uq_floors_building_level"),
    )
    op.create_index("ix_floors_building_id", "floors", ["building_id"])


def downgrade() -> None:
    op.drop_index("ix_floors_building_id", table_name="floors")
    op.drop_table("floors")
    op.drop_index("ix_buildings_owner_id", table_name="buildings")
    op.drop_table("buildings")
