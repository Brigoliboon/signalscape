from fastapi.testclient import TestClient


def test_openapi_spec_builds(client: TestClient) -> None:
    response = client.get("/api/openapi.json")
    assert response.status_code == 200
    spec = response.json()
    assert spec["info"]["title"]
    assert "/api/health" in spec["paths"]


def test_docs_load(client: TestClient) -> None:
    response = client.get("/api/docs")
    assert response.status_code == 200
    assert "swagger" in response.text.lower() or "openapi" in response.text.lower()


def test_redoc_load(client: TestClient) -> None:
    response = client.get("/api/redoc")
    assert response.status_code == 200
