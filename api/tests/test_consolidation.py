import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.models.user import UserRole
from app.services.consolidation import OUTDOOR_AREA_ID
from tests.helpers import (
    auth_headers,
    make_building,
    make_floor,
    make_survey,
    make_user,
)
from tests.test_results import add_readings

A = "aa:bb:cc:dd:ee:01"
B = "aa:bb:cc:dd:ee:02"


class World:
    def __init__(self, client: TestClient, db: Session) -> None:
        self.client = client
        self.db = db
        self.owner = make_user(db, consented=True)
        self.headers = auth_headers(client, self.owner)
        self.admin = make_user(db, role=UserRole.ADMIN, name="DTO admin")
        self.admin_headers = auth_headers(client, self.admin)
        self.building = make_building(db, self.owner, name="CISC")
        self.floor = make_floor(db, self.building, level=0)
        self.survey = make_survey(db, self.building, self.owner)
        self.site_id = self.make_site(
            name="CISC campus", building_ids=[str(self.building.id)]
        )

    def make_site(self, **overrides) -> str:
        payload = {"name": f"Site {uuid.uuid4().hex[:8]}"}
        payload.update(overrides)
        response = self.client.post("/api/sites", json=payload, headers=self.headers)
        assert response.status_code == 201, response.text
        return response.json()["id"]

    def consolidate(
        self, survey_ids: list[uuid.UUID], site_id: str | None = None, headers=None
    ):
        return self.client.post(
            f"/api/sites/{site_id or self.site_id}/consolidate",
            json={"survey_ids": [str(sid) for sid in survey_ids]},
            headers=headers or self.admin_headers,
        )


@pytest.fixture
def world(client: TestClient, db_session: Session) -> World:
    return World(client, db_session)


def test_consolidate_merges_two_surveys(world: World) -> None:
    other_building = make_building(world.db, world.owner, name="Annex")
    other_floor = make_floor(world.db, other_building, level=1)
    other_survey = make_survey(world.db, other_building, world.owner)
    add_readings(
        world.db,
        world.survey,
        world.floor,
        [(0.5, 0.5, -50, A), (2.5, 0.5, -55, A), (4.5, 0.5, -60, A)],
    )
    add_readings(
        world.db,
        other_survey,
        other_floor,
        [(0.5, 0.5, -65, B), (2.5, 0.5, -70, B), (4.5, 0.5, -75, B)],
    )
    site_id = world.make_site(
        building_ids=[str(world.building.id), str(other_building.id)]
    )
    response = world.consolidate([world.survey.id, other_survey.id], site_id=site_id)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["survey_ids"] == [str(world.survey.id), str(other_survey.id)]
    assert {floor["floor_id"] for floor in body["floors"]} == {
        str(world.floor.id),
        str(other_floor.id),
    }
    assert {grid["floor_id"] for grid in body["grids"]} == {
        str(world.floor.id),
        str(other_floor.id),
    }
    assert {ap["bssid"] for ap in body["access_points"]} == {A, B}
    assert body["thresholds"] == {
        "good_dbm": world.admin.good_threshold_dbm,
        "dead_dbm": world.admin.dead_threshold_dbm,
    }
    assert all(grid["method"] == "idw" for grid in body["grids"])


def test_survey_must_belong_to_a_building_in_the_site(world: World) -> None:
    other_building = make_building(world.db, world.owner, name="Elsewhere")
    other_survey = make_survey(world.db, other_building, world.owner)
    response = world.consolidate([other_survey.id])
    assert response.status_code == 400
    assert "building in this site" in response.json()["detail"]


def test_duplicate_survey_ids_are_rejected(world: World) -> None:
    response = world.consolidate([world.survey.id, world.survey.id])
    assert response.status_code == 422


def test_outdoor_polygon_groups_readings_as_outdoor(world: World) -> None:
    add_readings(
        world.db,
        world.survey,
        world.floor,
        [(0.5, 0.5, -50, A), (2.5, 0.5, -55, A), (4.5, 0.5, -60, A)],
    )
    polygon = [
        {"lat": 14.5990, "lng": 120.9830},
        {"lat": 14.6000, "lng": 120.9830},
        {"lat": 14.6000, "lng": 120.9850},
        {"lat": 14.5990, "lng": 120.9850},
    ]
    site_id = world.make_site(
        building_ids=[str(world.building.id)], outdoor_area=polygon
    )
    response = world.consolidate([world.survey.id], site_id=site_id)
    assert response.status_code == 200, response.text
    body = response.json()
    assert {floor["floor_id"] for floor in body["floors"]} == {str(OUTDOOR_AREA_ID)}
    assert body["floors"][0]["floor_label"] == "Outdoor"
    assert all(grid["floor_id"] == str(OUTDOOR_AREA_ID) for grid in body["grids"])


def test_weak_access_point_has_no_position(world: World) -> None:
    add_readings(
        world.db,
        world.survey,
        world.floor,
        [(0.5, 0.5, -88, B), (2.5, 0.5, -90, B), (4.5, 0.5, -92, B)],
    )
    response = world.consolidate([world.survey.id])
    assert response.status_code == 200, response.text
    aps = [ap for ap in response.json()["access_points"] if ap["bssid"] == B]
    assert len(aps) == 1
    assert aps[0]["position_determined"] is False
    assert aps[0]["lat"] is None and aps[0]["lng"] is None


def test_surveyor_cannot_consolidate_another_surveyors_work(world: World) -> None:
    other_owner = make_user(world.db, consented=True)
    other_building = make_building(world.db, other_owner, name="Private")
    other_survey = make_survey(world.db, other_building, other_owner)
    response = world.consolidate([other_survey.id], headers=world.headers)
    assert response.status_code == 404
