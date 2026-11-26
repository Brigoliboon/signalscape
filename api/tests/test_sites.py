import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.models.user import UserRole
from tests.helpers import (
    auth_headers,
    make_building,
    make_user,
)


def site_payload(**overrides) -> dict:
    payload = {"name": "CISC campus"}
    payload.update(overrides)
    return payload


class World:
    def __init__(self, client: TestClient, db: Session) -> None:
        self.client = client
        self.db = db
        self.owner = make_user(db, consented=True)
        self.headers = auth_headers(client, self.owner)
        self.building = make_building(db, self.owner, name="CISC")
        self.admin = make_user(db, role=UserRole.ADMIN, name="Admin")
        self.admin_headers = auth_headers(client, self.admin)
        self.viewer = make_user(db, role=UserRole.VIEWER, name="Viewer")
        self.viewer_headers = auth_headers(client, self.viewer)


@pytest.fixture
def world(client: TestClient, db_session: Session) -> World:
    return World(client, db_session)


def create(world: World, **overrides):
    return world.client.post(
        "/api/sites", json=site_payload(**overrides), headers=world.headers
    )


# --- login and roles --------------------------------------------------------


def test_sites_require_login(client: TestClient) -> None:
    sid = uuid.uuid4()
    assert client.get("/api/sites").status_code == 401
    assert client.post("/api/sites", json={}).status_code == 401
    assert client.get(f"/api/sites/{sid}").status_code == 401
    assert client.patch(f"/api/sites/{sid}", json={}).status_code == 401
    assert client.delete(f"/api/sites/{sid}").status_code == 401
    assert client.post(f"/api/sites/{sid}/consolidate", json={}).status_code == 401


def test_viewer_cannot_write_and_sees_no_sites(world: World) -> None:
    created = create(world)
    assert created.status_code == 201
    sid = created.json()["id"]
    assert (
        world.client.post(
            "/api/sites", json=site_payload(name="Other"), headers=world.viewer_headers
        ).status_code
        == 403
    )
    assert (
        world.client.patch(
            f"/api/sites/{sid}", json={"name": "x"}, headers=world.viewer_headers
        ).status_code
        == 403
    )
    assert (
        world.client.delete(
            f"/api/sites/{sid}", headers=world.viewer_headers
        ).status_code
        == 403
    )
    assert (
        world.client.get("/api/sites", headers=world.viewer_headers).json()["items"]
        == []
    )


def test_surveyor_sees_only_own_sites_and_admin_sees_all(world: World) -> None:
    own = create(world, name="Mine")
    assert own.status_code == 201
    other_owner = make_user(world.db, consented=True)
    other_headers = auth_headers(world.client, other_owner)
    other = world.client.post(
        "/api/sites", json=site_payload(name="Theirs"), headers=other_headers
    )
    assert other.status_code == 201
    assert [
        s["name"]
        for s in world.client.get("/api/sites", headers=world.headers).json()["items"]
    ] == ["Mine"]
    assert {
        s["name"]
        for s in world.client.get("/api/sites", headers=world.admin_headers).json()[
            "items"
        ]
    } == {"Mine", "Theirs"}


# --- CRUD -------------------------------------------------------------------


def test_create_site_with_buildings_and_outdoor_area(world: World) -> None:
    response = create(
        world,
        building_ids=[str(world.building.id)],
        outdoor_area=[
            {"lat": 14.5990, "lng": 120.9830},
            {"lat": 14.6000, "lng": 120.9830},
            {"lat": 14.6000, "lng": 120.9850},
        ],
        description="Grounds between the buildings",
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["owner_id"] == str(world.owner.id)
    assert body["building_ids"] == [str(world.building.id)]
    assert len(body["outdoor_area"]) == 3
    detail = world.client.get(f"/api/sites/{body['id']}", headers=world.headers)
    assert detail.status_code == 200
    assert [b["name"] for b in detail.json()["buildings"]] == ["CISC"]


def test_duplicate_name_for_the_same_owner_is_409(world: World) -> None:
    assert create(world).status_code == 201
    response = create(world)
    assert response.status_code == 409
    assert "already have a site" in response.json()["detail"]


def test_update_and_delete_site(world: World) -> None:
    sid = create(world, building_ids=[str(world.building.id)]).json()["id"]
    updated = world.client.patch(
        f"/api/sites/{sid}",
        json={"name": "Main campus", "building_ids": []},
        headers=world.headers,
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["name"] == "Main campus"
    assert (
        world.client.get(f"/api/sites/{sid}", headers=world.headers).json()["buildings"]
        == []
    )
    assert (
        world.client.delete(f"/api/sites/{sid}", headers=world.headers).status_code
        == 204
    )
    assert (
        world.client.get(f"/api/sites/{sid}", headers=world.headers).status_code == 404
    )


def test_building_ids_must_be_visible(world: World) -> None:
    other_owner = make_user(world.db, consented=True)
    other_building = make_building(world.db, other_owner, name="Hidden")
    response = create(world, building_ids=[str(other_building.id)])
    assert response.status_code == 404


# --- validation, pagination, filtering and sorting --------------------------


@pytest.mark.parametrize(
    "payload",
    [
        {"name": ""},
        {"name": "   "},
        {"name": "Too long " * 30},
        {"name": "Area", "outdoor_area": [{"lat": 14.6, "lng": 121.0}]},
        {"name": "Area", "outdoor_area": [{"lat": 200, "lng": 121.0}] * 3},
    ],
)
def test_create_validation(world: World, payload: dict) -> None:
    response = world.client.post("/api/sites", json=payload, headers=world.headers)
    assert response.status_code == 422


def test_list_pagination_search_and_sort(world: World) -> None:
    for name in ("Zeta", "Alpha"):
        assert create(world, name=name).status_code == 201
    assert create(world, name="Beta campus", description="A campus").status_code == 201
    body = world.client.get(
        "/api/sites",
        params={"page": 1, "page_size": 2, "sort": "name"},
        headers=world.headers,
    ).json()
    assert body["total"] == 3
    assert [s["name"] for s in body["items"]] == ["Alpha", "Beta campus"]
    found = world.client.get(
        "/api/sites", params={"q": "campus"}, headers=world.headers
    ).json()
    assert [s["name"] for s in found["items"]] == ["Beta campus"]
    assert (
        world.client.get(
            "/api/sites", params={"sort": "nope"}, headers=world.headers
        ).status_code
        == 422
    )


def test_owner_filter_is_admin_only(world: World) -> None:
    create(world)
    assert (
        world.client.get(
            "/api/sites",
            params={"owner_id": str(world.owner.id)},
            headers=world.headers,
        ).status_code
        == 403
    )
    body = world.client.get(
        "/api/sites",
        params={"owner_id": str(world.owner.id)},
        headers=world.admin_headers,
    ).json()
    assert body["total"] == 1
