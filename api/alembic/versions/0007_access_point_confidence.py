"""Placement confidence on access point estimates (FR-23 to FR-25).

Existing rows keep the three new columns null (read as low confidence until the
survey is processed again).

Revision ID: 0007
Revises: 0006
Create Date: 2026-11-18
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0007"
down_revision: Union[str, Sequence[str], None] = "0006"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "access_point_estimates", sa.Column("confidence", sa.REAL(), nullable=True)
    )
    op.add_column(
        "access_point_estimates",
        sa.Column("low_confidence", sa.Boolean(), nullable=True),
    )
    op.add_column(
        "access_point_estimates", sa.Column("spread_m", sa.REAL(), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("access_point_estimates", "spread_m")
    op.drop_column("access_point_estimates", "low_confidence")
    op.drop_column("access_point_estimates", "confidence")
