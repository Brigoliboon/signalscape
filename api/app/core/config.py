from functools import lru_cache

from pydantic import Field
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
    access_token_expire_minutes: int = 60 * 24
    bcrypt_rounds: int = Field(default=12, ge=4, le=15)


@lru_cache
def get_settings() -> Settings:
    return Settings()
