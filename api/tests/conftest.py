import os
from collections.abc import Generator
from pathlib import Path

# Fast bcrypt for tests. Must be set before the app reads its settings.
os.environ.setdefault("BCRYPT_ROUNDS", "4")

import pytest  # noqa: E402
from alembic import command  # noqa: E402
from alembic.config import Config  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy.orm import Session  # noqa: E402

from app.api.deps import get_uploads_dir  # noqa: E402
from app.core.config import get_settings  # noqa: E402
from app.db.session import engine, get_db  # noqa: E402
from app.main import app  # noqa: E402


@pytest.fixture(scope="session", autouse=True)
def apply_migrations() -> None:
    settings = get_settings()
    cfg = Config("alembic.ini")
    cfg.set_main_option("sqlalchemy.url", settings.database_url.replace("%", "%%"))
    command.upgrade(cfg, "head")


@pytest.fixture
def db_session() -> Generator[Session, None, None]:
    """A session inside a transaction that is rolled back after each test.

    Commits made by the app (or the test) only release a savepoint, so tests never
    leave rows behind and cannot see each other's data.
    """
    connection = engine.connect()
    transaction = connection.begin()
    session = Session(
        bind=connection,
        autoflush=False,
        join_transaction_mode="create_savepoint",
    )
    try:
        yield session
    finally:
        session.close()
        transaction.rollback()
        connection.close()


@pytest.fixture
def client(db_session: Session) -> Generator[TestClient, None, None]:
    app.dependency_overrides[get_db] = lambda: db_session
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()


@pytest.fixture(autouse=True)
def uploads_dir(tmp_path: Path) -> Generator[Path, None, None]:
    """Send floor plan uploads to a temporary folder instead of /data/uploads."""
    folder = tmp_path / "uploads"
    app.dependency_overrides[get_uploads_dir] = lambda: folder
    yield folder
    app.dependency_overrides.pop(get_uploads_dir, None)
