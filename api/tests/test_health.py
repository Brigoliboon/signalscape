from fastapi import HTTPException
from fastapi.testclient import TestClient
from sqlalchemy.exc import SQLAlchemyError

from app.api.health import health


def test_health_ok(client: TestClient) -> None:
    response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_health_reports_database_failure() -> None:
    class FakeSession:
        def execute(self, _statement: object) -> None:
            raise SQLAlchemyError("connection refused")

    try:
        health(db=FakeSession())  # type: ignore[arg-type]
    except HTTPException as exc:
        assert exc.status_code == 503
        assert exc.detail == "database unavailable"
    else:
        raise AssertionError("expected HTTPException")
