"""ORM models. Import every model here so Alembic sees them in Base.metadata."""

from app.models.user import User, UserRole

__all__ = ["User", "UserRole"]
