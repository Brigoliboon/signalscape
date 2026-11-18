"""GET /surveys/{id}/routers: router coverage mode (FR-27 to FR-29)."""

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.models.survey import SurveyStatus
from app.models.user import UserRole
from tests.helpers import make_floor, make_user
from tests.test_results import add_readings
from tests.test_surveys import World

# One radio with two names (staff and guest) and an extender with staff only.
STAFF = "aa:bb:cc:dd:ee:10"
GUEST = "aa:bb:cc:dd:ee:11"
EXTENDER = "11:22:33:44:55:60"
LONE = "77:66:55:44:33:20"


def corridor_walk() -> list[tuple]:
    """A 20 m corridor walked along y = 0.5 and y = 2.5. The main router is at
    the west end, the extender at the east end, and the middle is dead."""
    points = []
    for y in (0.5, 2.5):
        for x in range(0, 21):
            west = -35 - 6 * x
            east = -40 - 6 * (20 - x)
            if west >= -95:
                points.append((x + 0.5, y, west, STAFF, "staff"))
                points.append((x + 0.5, y, west - 2, GUEST, "guest"))
            if east >= -95:
                points.append((x + 0.5, y, east, EXTENDER, "staff"))
    return points


class RouterScene(World):
    def __init__(self, client: TestClient, db: Session) -> None:
        super().__init__(client, db)
        self.upper = make_floor(db, self.building, level=1)
        add_readings(db, self.survey, self.floor, corridor_walk())
        add_readings(
            db,
            self.survey,
            self.upper,
            [(x + 0.5, 0.5, -50 - x, LONE, "lab") for x in range(6)],
            start=1000,
        )

    def processed(self) -> "RouterScene":
        self.survey.status = SurveyStatus.COMPLETED
        self.db.commit()
        assert (
            self.client.post(f"{self.url}/process", headers=self.headers).status_code
            == 200
        )
        return self

    def routers(self, params: str = "", headers: dict | None = None):
        return self.client.get(
            f"{self.url}/routers{params}", headers=headers or self.headers
        )


@pytest.fixture
def scene(client: TestClient, db_session: Session) -> RouterScene:
    return RouterScene(client, db_session)


def test_routers_need_login_and_a_processed_survey(scene: RouterScene) -> None:
    assert scene.client.get(f"{scene.url}/routers").status_code == 401
    assert scene.routers().status_code == 409
    scene.processed()
    other = make_user(scene.db, consented=True)
    assert scene.routers(headers=scene.headers_for(other)).status_code == 404
    missing = f"/api/surveys/{uuid.uuid4()}/routers"
    assert scene.client.get(missing, headers=scene.headers).status_code == 404
    assert scene.routers("?floor_id=nope").status_code == 422


def test_one_radio_with_two_names_counts_as_one_router(scene: RouterScene) -> None:
    body = scene.processed().routers().json()
    assert body["bssid_count"] == 4
    assert body["router_count"] == 3
    assert "high nibble" in body["grouping"]
    assert body["thresholds"] == {"good_dbm": -67, "dead_dbm": -80}
    ground, upper = body["floors"]
    assert (ground["floor_level"], upper["floor_level"]) == (0, 1)
    assert ground["router_count"] == 2
    main, extender = ground["routers"]
    assert (main["number"], main["label"]) == (1, "Router 1")
    assert main["router_id"] == STAFF
    assert main["ssids"] == ["guest", "staff"]
    assert {n["bssid"] for n in main["networks"]} == {STAFF, GUEST}
    assert main["max_rssi_dbm"] == -35
    assert extender["ssids"] == ["staff"]
    assert [n["bssid"] for n in extender["networks"]] == [EXTENDER]
    assert upper["routers"][0]["ssids"] == ["lab"]
    assert upper["chains"] == []


def test_each_router_has_a_footprint_and_a_position(scene: RouterScene) -> None:
    ground = scene.processed().routers().json()["floors"][0]
    main, extender = ground["routers"]
    for router in (main, extender):
        grid = router["footprint"]
        assert len(grid["values"]) == grid["cols"] * grid["rows"]
        assert grid["north_lat"] > grid["origin_lat"]
        assert grid["east_lng"] > grid["origin_lng"]
        assert grid["cell_size_m"] == 1.0
        assert 0 < router["good_area_m2"] <= router["area_m2"]
        assert router["lat"] is not None and router["lng"] is not None
        assert router["low_confidence"] is not None
    # The main router covers the west end, the extender the east end.
    assert main["footprint"]["origin_lng"] < extender["footprint"]["origin_lng"]
    assert main["lng"] < extender["lng"]


def test_chain_of_a_router_and_its_extender_shows_the_dead_gap(
    scene: RouterScene,
) -> None:
    ground = scene.processed().routers().json()["floors"][0]
    [chain] = ground["chains"]
    assert chain["ssids"] == ["staff"]
    assert chain["router_ids"] == [STAFF, EXTENDER]
    [link] = chain["links"]
    assert (link["from_router"], link["to_router"]) == (STAFF, EXTENDER)
    assert link["status"] == "dead"
    assert link["dead_m"] > 0
    assert link["min_rssi_dbm"] < -80
    assert chain["dead_cells"] > 0
    assert chain["gap_area_m2"] == chain["weak_cells"] + chain["dead_cells"]
    gaps = chain["gaps"]
    assert len(gaps["values"]) == gaps["cols"] * gaps["rows"]
    shown = [v for v in gaps["values"] if v is not None]
    assert len(shown) == chain["weak_cells"] + chain["dead_cells"]
    assert all(v < -67 for v in shown)


def test_routers_can_be_limited_to_one_floor(scene: RouterScene) -> None:
    scene.processed()
    body = scene.routers(f"?floor_id={scene.upper.id}").json()
    assert [f["floor_level"] for f in body["floors"]] == [1]
    assert body["router_count"] == 3  # the survey total stays
    assert scene.routers(f"?floor_id={uuid.uuid4()}").json()["floors"] == []


def test_viewer_reads_routers_of_shared_surveys(scene: RouterScene) -> None:
    scene.processed()
    viewer = make_user(scene.db, role=UserRole.VIEWER)
    headers = scene.headers_for(viewer)
    assert scene.routers(headers=headers).status_code == 404
    shared = scene.client.post(
        f"{scene.url}/shares", headers=scene.headers, json={"email": viewer.email}
    )
    assert shared.status_code == 201
    assert scene.routers(headers=headers).status_code == 200


def test_routers_route_is_documented(client: TestClient) -> None:
    paths = client.get("/api/openapi.json").json()["paths"]
    assert "/api/surveys/{survey_id}/routers" in paths
