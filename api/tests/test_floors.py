import uuid
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.models.building import Building, Floor
from app.models.user import User, UserRole
from app.services.buildings import MAX_PLAN_BYTES
from tests.helpers import (
    JPEG_BYTES,
    PNG_BYTES,
    auth_headers,
    make_building,
    make_floor,
    make_user,
)


def setup_floor(
    client: TestClient, db: Session, role: UserRole = UserRole.SURVEYOR
) -> tuple[User, Building, Floor, dict[str, str]]:
    owner = make_user(db, role=role)
    building = make_building(db, owner)
    floor = make_floor(db, building)
    return owner, building, floor, auth_headers(client, owner)


def upload(
    client: TestClient,
    floor: Floor,
    headers: dict[str, str],
    content: bytes = PNG_BYTES,
    name: str = "plan.png",
    content_type: str = "image/png",
):
    return client.put(
        f"/api/floors/{floor.id}/plan",
        headers=headers,
        files={"file": (name, content, content_type)},
    )


# --- list and create --------------------------------------------------------


def test_create_floor_with_all_fields(client: TestClient, db_session: Session) -> None:
    _, building, _, headers = setup_floor(client, db_session)
    response = client.post(
        f"/api/buildings/{building.id}/floors",
        headers=headers,
        json={
            "level": -1,
            "label": " B1 ",
            "width_m": 30.5,
            "length_m": 20,
            "height_m": 2.8,
        },
    )
    assert response.status_code == 201
    body = response.json()
    assert body["building_id"] == str(building.id)
    assert (body["level"], body["label"]) == (-1, "B1")
    assert (body["width_m"], body["length_m"], body["height_m"]) == (30.5, 20.0, 2.8)
    assert body["plan_url"] is None
    assert "plan_image_path" not in body


def test_create_floor_size_is_optional(client: TestClient, db_session: Session) -> None:
    _, building, _, headers = setup_floor(client, db_session)
    response = client.post(
        f"/api/buildings/{building.id}/floors",
        headers=headers,
        json={"level": 3, "label": "4F"},
    )
    assert response.status_code == 201
    body = response.json()
    assert body["width_m"] is None and body["length_m"] is None
    assert body["height_m"] == 3.0


@pytest.mark.parametrize(
    "payload",
    [
        {"label": "G"},
        {"level": 0},
        {"level": 0, "label": ""},
        {"level": 0, "label": "  "},
        {"level": 0, "label": "G", "width_m": 0},
        {"level": 0, "label": "G", "length_m": -2},
        {"level": 0, "label": "G", "width_m": 10000},
        {"level": 0, "label": "G", "height_m": 0},
        {"level": 0, "label": "G", "height_m": 100},
        {"level": 201, "label": "G"},
        {"level": -21, "label": "G"},
        {"level": "ground", "label": "G"},
    ],
)
def test_create_floor_validation(
    client: TestClient, db_session: Session, payload: dict
) -> None:
    _, building, _, headers = setup_floor(client, db_session)
    url = f"/api/buildings/{building.id}/floors"
    assert client.post(url, headers=headers, json=payload).status_code == 422


def test_duplicate_floor_level_is_409(client: TestClient, db_session: Session) -> None:
    _, building, floor, headers = setup_floor(client, db_session)
    url = f"/api/buildings/{building.id}/floors"
    dup = client.post(url, headers=headers, json={"level": floor.level, "label": "x"})
    assert dup.status_code == 409
    other = make_building(db_session, db_session.get(User, building.owner_id))
    ok = client.post(
        f"/api/buildings/{other.id}/floors",
        headers=headers,
        json={"level": floor.level, "label": "same level, other building"},
    )
    assert ok.status_code == 201


def test_list_floors_sorted_and_paginated(
    client: TestClient, db_session: Session
) -> None:
    owner = make_user(db_session)
    building = make_building(db_session, owner)
    for level in (3, 0, 2, -1, 1):
        make_floor(db_session, building, level=level)
    headers = auth_headers(client, owner)
    url = f"/api/buildings/{building.id}/floors"

    def levels(query: str) -> list[int]:
        response = client.get(f"{url}?{query}", headers=headers)
        assert response.status_code == 200
        return [f["level"] for f in response.json()["items"]]

    assert levels("") == [-1, 0, 1, 2, 3]
    assert levels("sort=-level") == [3, 2, 1, 0, -1]
    assert levels("page=2&page_size=2") == [1, 2]
    body = client.get(f"{url}?page_size=2", headers=headers).json()
    assert body["total"] == 5
    assert client.get(f"{url}?sort=label", headers=headers).status_code == 422


def test_list_floors_only_for_that_building(
    client: TestClient, db_session: Session
) -> None:
    owner = make_user(db_session)
    first = make_building(db_session, owner)
    second = make_building(db_session, owner)
    make_floor(db_session, first, level=0)
    make_floor(db_session, second, level=0)
    make_floor(db_session, second, level=1)
    headers = auth_headers(client, owner)
    body = client.get(f"/api/buildings/{second.id}/floors", headers=headers).json()
    assert body["total"] == 2


# --- update and delete ------------------------------------------------------


def test_update_floor(client: TestClient, db_session: Session) -> None:
    _, _, floor, headers = setup_floor(client, db_session)
    url = f"/api/floors/{floor.id}"
    response = client.patch(
        url, headers=headers, json={"label": "Ground", "width_m": 12.25, "level": 5}
    )
    assert response.status_code == 200
    body = response.json()
    assert (body["label"], body["width_m"], body["level"]) == ("Ground", 12.25, 5)
    # Size can be cleared again; other fields stay.
    cleared = client.patch(url, headers=headers, json={"width_m": None}).json()
    assert cleared["width_m"] is None and cleared["label"] == "Ground"


@pytest.mark.parametrize(
    "payload",
    [
        {"level": None},
        {"label": None},
        {"height_m": None},
        {"label": " "},
        {"width_m": 0},
        {"level": 999},
    ],
)
def test_update_floor_validation(
    client: TestClient, db_session: Session, payload: dict
) -> None:
    _, _, floor, headers = setup_floor(client, db_session)
    assert (
        client.patch(
            f"/api/floors/{floor.id}", headers=headers, json=payload
        ).status_code
        == 422
    )


def test_update_floor_level_conflict(client: TestClient, db_session: Session) -> None:
    _, building, floor, headers = setup_floor(client, db_session)
    other = make_floor(db_session, building, level=4)
    url = f"/api/floors/{other.id}"
    assert (
        client.patch(url, headers=headers, json={"level": floor.level}).status_code
        == 409
    )
    assert client.patch(url, headers=headers, json={"level": 4}).status_code == 200


def test_delete_floor(client: TestClient, db_session: Session) -> None:
    _, building, floor, headers = setup_floor(client, db_session)
    url = f"/api/floors/{floor.id}"
    assert client.delete(url, headers=headers).status_code == 204
    assert client.delete(url, headers=headers).status_code == 404
    listing = client.get(f"/api/buildings/{building.id}/floors", headers=headers)
    assert listing.json()["total"] == 0


def test_floor_routes_hide_other_users_floors(
    client: TestClient, db_session: Session
) -> None:
    _, _, floor, owner_headers = setup_floor(client, db_session)
    assert upload(client, floor, owner_headers).status_code == 200
    stranger = auth_headers(client, make_user(db_session))
    url = f"/api/floors/{floor.id}"
    assert client.patch(url, headers=stranger, json={"label": "x"}).status_code == 404
    assert client.delete(url, headers=stranger).status_code == 404
    assert upload(client, floor, stranger).status_code == 404
    assert client.get(f"{url}/plan", headers=stranger).status_code == 404
    admin = auth_headers(client, make_user(db_session, role=UserRole.ADMIN))
    assert client.get(f"{url}/plan", headers=admin).status_code == 200


def test_viewer_cannot_modify_floors(client: TestClient, db_session: Session) -> None:
    _, _, floor, owner_headers = setup_floor(client, db_session)
    assert upload(client, floor, owner_headers).status_code == 200
    viewer = auth_headers(client, make_user(db_session, role=UserRole.VIEWER))
    url = f"/api/floors/{floor.id}"
    assert client.patch(url, headers=viewer, json={"label": "x"}).status_code == 403
    assert client.delete(url, headers=viewer).status_code == 403
    assert upload(client, floor, viewer).status_code == 403
    # Reading something they cannot see is a 404, not a 403.
    assert client.get(f"{url}/plan", headers=viewer).status_code == 404


def test_floor_endpoints_require_login(client: TestClient) -> None:
    url = f"/api/floors/{uuid.uuid4()}"
    assert client.patch(url, json={}).status_code == 401
    assert client.delete(url).status_code == 401
    assert client.put(f"{url}/plan").status_code == 401
    assert client.get(f"{url}/plan").status_code == 401


# --- floor plan upload ------------------------------------------------------


def test_upload_png_and_download(
    client: TestClient, db_session: Session, uploads_dir: Path
) -> None:
    _, _, floor, headers = setup_floor(client, db_session)
    response = upload(client, floor, headers)
    assert response.status_code == 200
    assert response.json()["plan_url"] == f"/api/floors/{floor.id}/plan"
    assert (uploads_dir / f"{floor.id}.png").read_bytes() == PNG_BYTES
    image = client.get(f"/api/floors/{floor.id}/plan", headers=headers)
    assert image.status_code == 200
    assert image.headers["content-type"] == "image/png"
    assert image.content == PNG_BYTES


def test_upload_type_comes_from_content_not_name(
    client: TestClient, db_session: Session, uploads_dir: Path
) -> None:
    _, _, floor, headers = setup_floor(client, db_session)
    response = upload(
        client, floor, headers, JPEG_BYTES, name="plan.png", content_type="image/png"
    )
    assert response.status_code == 200
    assert (uploads_dir / f"{floor.id}.jpg").exists()
    image = client.get(f"/api/floors/{floor.id}/plan", headers=headers)
    assert image.headers["content-type"] == "image/jpeg"


def test_replacing_plan_removes_old_file(
    client: TestClient, db_session: Session, uploads_dir: Path
) -> None:
    _, _, floor, headers = setup_floor(client, db_session)
    assert upload(client, floor, headers).status_code == 200
    assert (
        upload(client, floor, headers, JPEG_BYTES, "p.jpg", "image/jpeg").status_code
        == 200
    )
    assert sorted(p.name for p in uploads_dir.iterdir()) == [f"{floor.id}.jpg"]
    # Same type again overwrites in place.
    new_png = PNG_BYTES + b"new"
    assert upload(client, floor, headers, new_png).status_code == 200
    assert sorted(p.name for p in uploads_dir.iterdir()) == [f"{floor.id}.png"]
    assert (
        client.get(f"/api/floors/{floor.id}/plan", headers=headers).content == new_png
    )


@pytest.mark.parametrize(
    "content",
    [b"", b"GIF89a....", b"%PDF-1.7 ....", b"<svg></svg>", b"\x89PNG", b"just text"],
)
def test_upload_rejects_other_types(
    client: TestClient, db_session: Session, uploads_dir: Path, content: bytes
) -> None:
    _, _, floor, headers = setup_floor(client, db_session)
    response = upload(client, floor, headers, content, "plan.png", "image/png")
    assert response.status_code == 415
    assert not uploads_dir.exists() or not list(uploads_dir.iterdir())
    db_session.refresh(floor)
    assert floor.plan_image_path is None


def test_upload_too_large_is_413(
    client: TestClient, db_session: Session, uploads_dir: Path
) -> None:
    _, _, floor, headers = setup_floor(client, db_session)
    big = PNG_BYTES + b"\x00" * (MAX_PLAN_BYTES - len(PNG_BYTES) + 1)
    assert len(big) == MAX_PLAN_BYTES + 1
    assert upload(client, floor, headers, big).status_code == 413
    assert not uploads_dir.exists() or not list(uploads_dir.iterdir())
    exactly = PNG_BYTES + b"\x00" * (MAX_PLAN_BYTES - len(PNG_BYTES))
    assert upload(client, floor, headers, exactly).status_code == 200


def test_upload_requires_a_file(client: TestClient, db_session: Session) -> None:
    _, _, floor, headers = setup_floor(client, db_session)
    assert (
        client.put(f"/api/floors/{floor.id}/plan", headers=headers).status_code == 422
    )


def test_failed_upload_keeps_existing_plan(
    client: TestClient, db_session: Session, uploads_dir: Path
) -> None:
    _, _, floor, headers = setup_floor(client, db_session)
    assert upload(client, floor, headers).status_code == 200
    assert upload(client, floor, headers, b"nope").status_code == 415
    assert (uploads_dir / f"{floor.id}.png").read_bytes() == PNG_BYTES


def test_get_plan_404_without_plan_or_file(
    client: TestClient, db_session: Session, uploads_dir: Path
) -> None:
    _, _, floor, headers = setup_floor(client, db_session)
    url = f"/api/floors/{floor.id}/plan"
    assert client.get(url, headers=headers).status_code == 404
    assert upload(client, floor, headers).status_code == 200
    (uploads_dir / f"{floor.id}.png").unlink()
    assert client.get(url, headers=headers).status_code == 404
    assert (
        client.get(f"/api/floors/{uuid.uuid4()}/plan", headers=headers).status_code
        == 404
    )


# --- plan files are removed with their owners -------------------------------


def test_delete_floor_removes_plan_file(
    client: TestClient, db_session: Session, uploads_dir: Path
) -> None:
    _, _, floor, headers = setup_floor(client, db_session)
    other = make_floor(db_session, db_session.get(Building, floor.building_id), level=1)
    assert upload(client, floor, headers).status_code == 200
    assert upload(client, other, headers).status_code == 200
    assert client.delete(f"/api/floors/{floor.id}", headers=headers).status_code == 204
    assert sorted(p.name for p in uploads_dir.iterdir()) == [f"{other.id}.png"]


def test_delete_building_removes_all_plan_files(
    client: TestClient, db_session: Session, uploads_dir: Path
) -> None:
    owner, building, floor, headers = setup_floor(client, db_session)
    second = make_floor(db_session, building, level=1)
    unrelated = make_floor(db_session, make_building(db_session, owner))
    for target in (floor, second, unrelated):
        assert upload(client, target, headers).status_code == 200
    response = client.delete(f"/api/buildings/{building.id}", headers=headers)
    assert response.status_code == 204
    assert sorted(p.name for p in uploads_dir.iterdir()) == [f"{unrelated.id}.png"]


def test_deleting_account_removes_plan_files(
    client: TestClient, db_session: Session, uploads_dir: Path
) -> None:
    _, _, floor, headers = setup_floor(client, db_session)
    assert upload(client, floor, headers).status_code == 200
    assert client.delete("/api/auth/me", headers=headers).status_code == 204
    assert list(uploads_dir.iterdir()) == []


def test_admin_deleting_user_removes_plan_files(
    client: TestClient, db_session: Session, uploads_dir: Path
) -> None:
    owner, _, floor, headers = setup_floor(client, db_session)
    assert upload(client, floor, headers).status_code == 200
    admin = auth_headers(client, make_user(db_session, role=UserRole.ADMIN))
    assert client.delete(f"/api/users/{owner.id}", headers=admin).status_code == 204
    assert list(uploads_dir.iterdir()) == []


def test_delete_building_tolerates_missing_files(
    client: TestClient, db_session: Session, uploads_dir: Path
) -> None:
    _, building, floor, headers = setup_floor(client, db_session)
    assert upload(client, floor, headers).status_code == 200
    (uploads_dir / f"{floor.id}.png").unlink()
    response = client.delete(f"/api/buildings/{building.id}", headers=headers)
    assert response.status_code == 204


def test_openapi_lists_building_routes(client: TestClient) -> None:
    paths = client.get("/api/openapi.json").json()["paths"]
    for path in (
        "/api/buildings",
        "/api/buildings/{building_id}",
        "/api/buildings/{building_id}/floors",
        "/api/floors/{floor_id}",
        "/api/floors/{floor_id}/plan",
    ):
        assert path in paths
