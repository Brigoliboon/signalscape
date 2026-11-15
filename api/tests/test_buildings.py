import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.models.building import Building
from app.models.user import UserRole
from tests.helpers import auth_headers, make_building, make_floor, make_user

# --- login and roles --------------------------------------------------------


def test_building_endpoints_require_login(client: TestClient) -> None:
    some_id = uuid.uuid4()
    assert client.get("/api/buildings").status_code == 401
    assert client.post("/api/buildings", json={"name": "x"}).status_code == 401
    assert client.get(f"/api/buildings/{some_id}").status_code == 401
    assert client.patch(f"/api/buildings/{some_id}", json={}).status_code == 401
    assert client.delete(f"/api/buildings/{some_id}").status_code == 401
    assert client.get(f"/api/buildings/{some_id}/floors").status_code == 401
    assert client.post(f"/api/buildings/{some_id}/floors", json={}).status_code == 401


def test_viewer_cannot_create_or_modify(
    client: TestClient, db_session: Session
) -> None:
    owner = make_user(db_session)
    building = make_building(db_session, owner)
    viewer = make_user(db_session, role=UserRole.VIEWER)
    headers = auth_headers(client, viewer)
    url = f"/api/buildings/{building.id}"
    assert (
        client.post("/api/buildings", headers=headers, json={"name": "x"}).status_code
        == 403
    )
    assert client.patch(url, headers=headers, json={"name": "y"}).status_code == 403
    assert client.delete(url, headers=headers).status_code == 403
    floor_post = client.post(
        f"{url}/floors", headers=headers, json={"level": 0, "label": "G"}
    )
    assert floor_post.status_code == 403
    db_session.refresh(building)
    assert building.name != "y"


def test_viewer_sees_no_buildings(client: TestClient, db_session: Session) -> None:
    make_building(db_session, make_user(db_session))
    building = make_building(db_session, make_user(db_session, role=UserRole.ADMIN))
    headers = auth_headers(client, make_user(db_session, role=UserRole.VIEWER))
    listing = client.get("/api/buildings", headers=headers)
    assert listing.status_code == 200
    assert listing.json()["items"] == []
    assert listing.json()["total"] == 0
    assert (
        client.get(f"/api/buildings/{building.id}", headers=headers).status_code == 404
    )
    floors = client.get(f"/api/buildings/{building.id}/floors", headers=headers)
    assert floors.status_code == 404


def test_surveyor_cannot_see_others_buildings(
    client: TestClient, db_session: Session
) -> None:
    other = make_building(db_session, make_user(db_session))
    headers = auth_headers(client, make_user(db_session))
    url = f"/api/buildings/{other.id}"
    assert client.get(url, headers=headers).status_code == 404
    assert client.patch(url, headers=headers, json={"name": "mine"}).status_code == 404
    assert client.delete(url, headers=headers).status_code == 404
    assert client.get(f"{url}/floors", headers=headers).status_code == 404
    post = client.post(
        f"{url}/floors", headers=headers, json={"level": 0, "label": "G"}
    )
    assert post.status_code == 404
    db_session.refresh(other)


def test_admin_sees_and_edits_everything(
    client: TestClient, db_session: Session
) -> None:
    owner = make_user(db_session)
    building = make_building(db_session, owner, name="Campus")
    headers = auth_headers(client, make_user(db_session, role=UserRole.ADMIN))
    url = f"/api/buildings/{building.id}"
    assert client.get(url, headers=headers).status_code == 200
    patched = client.patch(url, headers=headers, json={"address": "Manila"})
    assert patched.status_code == 200
    assert patched.json()["owner_id"] == str(owner.id)
    floor = client.post(
        f"{url}/floors", headers=headers, json={"level": 1, "label": "2F"}
    )
    assert floor.status_code == 201
    assert client.delete(url, headers=headers).status_code == 204
    assert client.get(url, headers=headers).status_code == 404


# --- create and read --------------------------------------------------------


def test_create_building(client: TestClient, db_session: Session) -> None:
    user = make_user(db_session)
    response = client.post(
        "/api/buildings",
        headers=auth_headers(client, user),
        json={"name": "  Engineering Hall ", "address": " ", "description": "Main"},
    )
    assert response.status_code == 201
    body = response.json()
    assert body["name"] == "Engineering Hall"
    assert body["address"] is None
    assert body["description"] == "Main"
    assert body["owner_id"] == str(user.id)


@pytest.mark.parametrize(
    "payload",
    [{}, {"name": ""}, {"name": "   "}, {"name": "x" * 201}, {"name": None}],
)
def test_create_building_validation(
    client: TestClient, db_session: Session, payload: dict
) -> None:
    headers = auth_headers(client, make_user(db_session))
    assert (
        client.post("/api/buildings", headers=headers, json=payload).status_code == 422
    )


def test_duplicate_name_per_owner_is_409(
    client: TestClient, db_session: Session
) -> None:
    owner = make_user(db_session)
    headers = auth_headers(client, owner)
    assert (
        client.post("/api/buildings", headers=headers, json={"name": "A"}).status_code
        == 201
    )
    dup = client.post("/api/buildings", headers=headers, json={"name": "A"})
    assert dup.status_code == 409
    # A different owner may reuse the name.
    other = auth_headers(client, make_user(db_session))
    assert (
        client.post("/api/buildings", headers=other, json={"name": "A"}).status_code
        == 201
    )


def test_get_building_includes_floors_sorted_by_level(
    client: TestClient, db_session: Session
) -> None:
    owner = make_user(db_session)
    building = make_building(db_session, owner)
    for level in (2, -1, 0):
        make_floor(db_session, building, level=level)
    response = client.get(
        f"/api/buildings/{building.id}", headers=auth_headers(client, owner)
    )
    assert response.status_code == 200
    assert [f["level"] for f in response.json()["floors"]] == [-1, 0, 2]


def test_get_building_unknown_id_is_404(
    client: TestClient, db_session: Session
) -> None:
    headers = auth_headers(client, make_user(db_session))
    assert (
        client.get(f"/api/buildings/{uuid.uuid4()}", headers=headers).status_code == 404
    )
    assert client.get("/api/buildings/not-a-uuid", headers=headers).status_code == 422


# --- update and delete ------------------------------------------------------


def test_update_building(client: TestClient, db_session: Session) -> None:
    owner = make_user(db_session)
    building = make_building(db_session, owner, name="Old", address="Somewhere")
    headers = auth_headers(client, owner)
    url = f"/api/buildings/{building.id}"
    response = client.patch(
        url, headers=headers, json={"name": "New", "address": None, "description": "d"}
    )
    assert response.status_code == 200
    body = response.json()
    assert (body["name"], body["address"], body["description"]) == ("New", None, "d")
    # Fields that are not sent stay the same.
    again = client.patch(url, headers=headers, json={"description": "e"})
    assert again.json()["name"] == "New"


def test_update_building_validation_and_conflict(
    client: TestClient, db_session: Session
) -> None:
    owner = make_user(db_session)
    make_building(db_session, owner, name="Taken")
    building = make_building(db_session, owner, name="Mine")
    headers = auth_headers(client, owner)
    url = f"/api/buildings/{building.id}"
    assert client.patch(url, headers=headers, json={"name": None}).status_code == 422
    assert client.patch(url, headers=headers, json={"name": " "}).status_code == 422
    assert client.patch(url, headers=headers, json={"name": "Taken"}).status_code == 409
    # Keeping its own name is fine.
    assert client.patch(url, headers=headers, json={"name": "Mine"}).status_code == 200
    # The failed update left the session usable and the name unchanged.
    assert client.get(url, headers=headers).json()["name"] == "Mine"


def test_delete_building_cascades_to_floors(
    client: TestClient, db_session: Session
) -> None:
    owner = make_user(db_session)
    building = make_building(db_session, owner)
    floor_id = make_floor(db_session, building).id
    headers = auth_headers(client, owner)
    assert (
        client.delete(f"/api/buildings/{building.id}", headers=headers).status_code
        == 204
    )
    db_session.expire_all()
    assert db_session.get(Building, building.id) is None
    assert (
        client.patch(
            f"/api/floors/{floor_id}", headers=headers, json={"label": "x"}
        ).status_code
        == 404
    )


# --- list: pagination, sort, filter -----------------------------------------


def test_list_only_returns_own_buildings(
    client: TestClient, db_session: Session
) -> None:
    owner = make_user(db_session)
    mine = [make_building(db_session, owner) for _ in range(2)]
    make_building(db_session, make_user(db_session))
    body = client.get("/api/buildings", headers=auth_headers(client, owner)).json()
    assert body["total"] == 2
    assert {item["id"] for item in body["items"]} == {str(b.id) for b in mine}


def test_list_pagination(client: TestClient, db_session: Session) -> None:
    owner = make_user(db_session)
    for index in range(5):
        make_building(db_session, owner, name=f"B{index}")
    headers = auth_headers(client, owner)
    first = client.get("/api/buildings?page=1&page_size=2", headers=headers).json()
    last = client.get("/api/buildings?page=3&page_size=2", headers=headers).json()
    assert first["total"] == 5 and first["page"] == 1 and first["page_size"] == 2
    assert [b["name"] for b in first["items"]] == ["B0", "B1"]
    assert [b["name"] for b in last["items"]] == ["B4"]
    assert client.get("/api/buildings?page=0", headers=headers).status_code == 422
    assert (
        client.get("/api/buildings?page_size=101", headers=headers).status_code == 422
    )


def test_list_sort(client: TestClient, db_session: Session) -> None:
    owner = make_user(db_session)
    for name in ("Beta", "Alpha", "Gamma"):
        make_building(db_session, owner, name=name)
    headers = auth_headers(client, owner)

    def names(sort: str) -> list[str]:
        response = client.get(f"/api/buildings?sort={sort}", headers=headers)
        return [b["name"] for b in response.json()["items"]]

    assert names("name") == ["Alpha", "Beta", "Gamma"]
    assert names("-name") == ["Gamma", "Beta", "Alpha"]
    # All three were created in one transaction, so created_at ties and the
    # id tie-breaker keeps the order stable between calls.
    assert names("created_at") == names("created_at")
    assert sorted(names("-created_at")) == ["Alpha", "Beta", "Gamma"]
    assert (
        client.get("/api/buildings?sort=owner_id", headers=headers).status_code == 422
    )


def test_list_search(client: TestClient, db_session: Session) -> None:
    owner = make_user(db_session)
    make_building(db_session, owner, name="Library", address="12 Rizal St")
    make_building(db_session, owner, name="Gym", address="100% Park")
    make_building(db_session, owner, name="Dorm", address="Elm")
    headers = auth_headers(client, owner)

    def found(q: str) -> list[str]:
        response = client.get("/api/buildings", params={"q": q}, headers=headers)
        return sorted(b["name"] for b in response.json()["items"])

    assert found("lib") == ["Library"]
    assert found("rizal") == ["Library"]
    assert found("%") == ["Gym"]  # wildcard characters are escaped
    assert found("_") == []
    assert found("  ") == ["Dorm", "Gym", "Library"]


def test_owner_filter_is_admin_only(client: TestClient, db_session: Session) -> None:
    alice = make_user(db_session)
    bob = make_user(db_session)
    make_building(db_session, alice, name="A")
    make_building(db_session, bob, name="B")
    admin = auth_headers(client, make_user(db_session, role=UserRole.ADMIN))
    filtered = client.get(f"/api/buildings?owner_id={alice.id}", headers=admin).json()
    assert [b["name"] for b in filtered["items"]] == ["A"]
    for role in (UserRole.SURVEYOR, UserRole.VIEWER):
        headers = auth_headers(client, make_user(db_session, role=role))
        response = client.get(f"/api/buildings?owner_id={alice.id}", headers=headers)
        assert response.status_code == 403
