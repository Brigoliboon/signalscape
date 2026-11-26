import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.core.config import Settings
from app.schemas.report import ReportUnavailable
from app.services import report as report_service
from tests.test_consolidation import World as ConsolidationWorld
from tests.test_results import Scene

A = "aa:bb:cc:dd:ee:01"


@pytest.fixture
def scene(client: TestClient, db_session: Session) -> Scene:
    return Scene(client, db_session)


@pytest.fixture
def processed(client: TestClient, db_session: Session) -> Scene:
    return Scene(client, db_session).processed()


@pytest.fixture
def campus(client: TestClient, db_session: Session) -> ConsolidationWorld:
    world = ConsolidationWorld(client, db_session)
    from tests.test_results import add_readings

    add_readings(
        db_session,
        world.survey,
        world.floor,
        [(0.5, 0.5, -50, A), (2.5, 0.5, -55, A), (4.5, 0.5, -60, A)],
    )
    return world


def fake_provider(prompt: str, settings) -> str:
    assert "Area-weighted signal" in prompt
    return "## Summary\nCoverage is mostly good.\n\n## Recommendations\nAdd one router."


def missing_provider(prompt: str, settings) -> str:
    raise ReportUnavailable(
        "AI report is not configured: set AI_API_KEY in the server secrets"
    )


# --- the figures stay available ---------------------------------------------


def test_survey_facts_work_without_a_provider(
    client: TestClient, processed: Scene
) -> None:
    response = processed.get("report/facts")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["scope"] == "survey"
    assert body["title"] == processed.building.name
    assert body["reading_count"] > 0
    assert body["thresholds"]["good_dbm"] == processed.owner.good_threshold_dbm
    assert len(body["floors"]) == 2


def test_report_needs_a_processed_survey(client: TestClient, scene: Scene) -> None:
    assert scene.get("report/facts").status_code == 409
    assert (
        scene.client.post(f"{scene.url}/report", headers=scene.headers).status_code
        == 409
    )


def test_call_provider_without_a_key_fails_clearly() -> None:
    with pytest.raises(ReportUnavailable, match="AI_API_KEY"):
        report_service.call_provider("figures", Settings(ai_api_key=None))


def test_missing_provider_gives_503_but_facts_still_work(
    client: TestClient, processed: Scene, monkeypatch
) -> None:
    monkeypatch.setattr(report_service, "call_provider", missing_provider)
    response = processed.client.post(
        f"{processed.url}/report", headers=processed.headers
    )
    assert response.status_code == 503
    assert "AI_API_KEY" in response.json()["detail"]
    assert processed.get("report/facts").status_code == 200


# --- generation and export --------------------------------------------------


def test_survey_report_is_written_from_the_facts(
    client: TestClient, processed: Scene, monkeypatch
) -> None:
    monkeypatch.setattr(report_service, "call_provider", fake_provider)
    response = processed.client.post(
        f"{processed.url}/report", headers=processed.headers
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["scope"] == "survey"
    assert body["provider"] == "openai-compatible"
    assert "## Summary" in body["markdown"]
    assert "## Recommendations" in body["markdown"]
    assert "## Coverage figures" in body["markdown"]
    assert body["facts"]["reading_count"] > 0


def test_report_can_be_exported_as_markdown(
    client: TestClient, processed: Scene, monkeypatch
) -> None:
    monkeypatch.setattr(report_service, "call_provider", fake_provider)
    response = processed.client.post(
        f"{processed.url}/report",
        params={"format": "md"},
        headers=processed.headers,
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/markdown")
    assert "attachment" in response.headers["content-disposition"]
    assert response.text.startswith("# ")


def test_report_requires_login(client: TestClient, processed: Scene) -> None:
    assert client.post(f"{processed.url}/report").status_code == 401
    assert client.get(f"{processed.url}/report/facts").status_code == 401


# --- consolidated site ------------------------------------------------------


def test_site_report_uses_consolidated_figures(
    client: TestClient, campus: ConsolidationWorld, monkeypatch
) -> None:
    monkeypatch.setattr(report_service, "call_provider", fake_provider)
    facts_response = campus.client.post(
        f"/api/sites/{campus.site_id}/report/facts",
        json={"survey_ids": [str(campus.survey.id)]},
        headers=campus.admin_headers,
    )
    assert facts_response.status_code == 200, facts_response.text
    assert facts_response.json()["scope"] == "site"

    response = campus.client.post(
        f"/api/sites/{campus.site_id}/report",
        json={"survey_ids": [str(campus.survey.id)]},
        headers=campus.admin_headers,
    )
    assert response.status_code == 200, response.text
    assert response.json()["facts"]["scope"] == "site"
    assert "## Coverage figures" in response.json()["markdown"]
