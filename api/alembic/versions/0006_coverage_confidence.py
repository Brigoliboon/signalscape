"""Per-cell confidence on coverage grids.

Existing rows keep ``confidence`` null (read as 1 until the survey is processed
again).

Revision ID: 0006
Revises: 0005
Create Date: 2026-11-16
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0006"
down_revision: Union[str, Sequence[str], None] = "0005"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "coverage_grids",
        sa.Column("confidence", postgresql.JSONB(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("coverage_grids", "confidence")
