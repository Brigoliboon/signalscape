from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_name: str = "SignalScape API"
    database_url: str = (
        "postgresql+psycopg://signalscape:signalscape@localhost:5432/signalscape"
    )
    jwt_secret: str = "change-me"
    jwt_algorithm: str = "HS256"


@lru_cache
def get_settings() -> Settings:
    return Settings()
