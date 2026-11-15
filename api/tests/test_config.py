from app.core.config import Settings, get_settings


def test_default_settings() -> None:
    settings = Settings(
        database_url="postgresql+psycopg://user:pass@localhost:5432/db",
        jwt_secret="test-secret",
    )
    assert settings.app_name == "SignalScape API"
    assert settings.jwt_algorithm == "HS256"
    assert "postgresql+psycopg://" in settings.database_url


def test_get_settings_cached() -> None:
    first = get_settings()
    second = get_settings()
    assert first is second


def test_uploads_dir_defaults_to_data_volume() -> None:
    from pathlib import Path

    from app.api.deps import get_uploads_dir

    assert Settings().uploads_dir == "/data/uploads"
    assert get_uploads_dir() == Path("/data/uploads")
