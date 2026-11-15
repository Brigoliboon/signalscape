from app.db.base import Base
from app.db.session import get_db


def test_get_db_yields_and_closes() -> None:
    gen = get_db()
    session = next(gen)
    assert session is not None
    gen.close()


def test_declarative_base_metadata() -> None:
    assert Base.metadata is not None
