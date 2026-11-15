import uuid
from datetime import UTC, datetime, timedelta

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.api.deps import require_role
from app.models.user import User, UserRole
from tests.helpers import auth_headers, clear_admins, make_user


def admin_headers(client: TestClient, db: Session) -> dict[str, str]:
    return auth_headers(client, make_user(db, role=UserRole.ADMIN))


# --- role enforcement -------------------------------------------------------


def test_users_endpoints_require_login(client: TestClient) -> None:
    some_id = uuid.uuid4()
    assert client.get("/api/users").status_code == 401
    assert client.get(f"/api/users/{some_id}").status_code == 401
    assert client.patch(f"/api/users/{some_id}", json={}).status_code == 401
    assert client.delete(f"/api/users/{some_id}").status_code == 401


def test_users_endpoints_forbidden_for_non_admins(
    client: TestClient, db_session: Session
) -> None:
    target = make_user(db_session)
    for role in (UserRole.SURVEYOR, UserRole.VIEWER):
        headers = auth_headers(client, make_user(db_session, role=role))
        assert client.get("/api/users", headers=headers).status_code == 403
        url = f"/api/users/{target.id}"
        assert client.get(url, headers=headers).status_code == 403
        patch = client.patch(url, headers=headers, json={"role": "admin"})
        assert patch.status_code == 403
        assert client.delete(url, headers=headers).status_code == 403
    db_session.refresh(target)
    assert target.role == UserRole.SURVEYOR


def test_role_comes_from_database_not_token(
    client: TestClient, db_session: Session
) -> None:
    user = make_user(db_session, role=UserRole.ADMIN)
    headers = auth_headers(client, user)
    assert client.get("/api/users", headers=headers).status_code == 200
    user.role = UserRole.VIEWER
    db_session.commit()
    assert client.get("/api/users", headers=headers).status_code == 403


def test_require_role_allows_any_listed_role(
    client: TestClient, db_session: Session
) -> None:
    from fastapi import Depends, FastAPI

    from app.db.session import get_db

    mini = FastAPI()

    admin_or_surveyor = require_role(UserRole.ADMIN, UserRole.SURVEYOR)

    @mini.get("/x")
    def route(user: User = Depends(admin_or_surveyor)):
        return {"role": user.role}

    mini.dependency_overrides[get_db] = lambda: db_session
    with TestClient(mini) as mini_client:
        for role, status in (
            (UserRole.ADMIN, 200),
            (UserRole.SURVEYOR, 200),
            (UserRole.VIEWER, 403),
        ):
            user = make_user(db_session, role=role)
            token = auth_headers(client, user)
            assert mini_client.get("/x", headers=token).status_code == status


# --- list: pagination, sorting, filters -------------------------------------


def seed_people(db: Session) -> str:
    """Create 5 users sharing a unique name tag so queries can isolate them."""
    tag = uuid.uuid4().hex[:8]
    now = datetime.now(UTC)
    rows = [
        ("Carla", UserRole.SURVEYOR, True),
        ("Alice", UserRole.SURVEYOR, False),
        ("Eve", UserRole.VIEWER, True),
        ("Bob", UserRole.VIEWER, True),
        ("Dan", UserRole.ADMIN, True),
    ]
    for i, (name, role, active) in enumerate(rows):
        user = make_user(
            db,
            role=role,
            is_active=active,
            name=f"{name} {tag}",
            email=f"{name.lower()}.{tag}@example.com",
        )
        user.created_at = now - timedelta(minutes=10 - i)  # Carla oldest
    db.commit()
    return tag


def names(response) -> list[str]:
    return [item["name"].split()[0] for item in response.json()["items"]]


def test_list_users_default_shape(client: TestClient, db_session: Session) -> None:
    headers = admin_headers(client, db_session)
    seed_people(db_session)
    response = client.get("/api/users", headers=headers)
    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"items", "total", "page", "page_size"}
    assert body["page"] == 1
    assert body["page_size"] == 20
    assert body["total"] >= 6
    assert "password_hash" not in body["items"][0]
    created = [item["created_at"] for item in body["items"]]
    assert created == sorted(created, reverse=True)  # default is newest first


def test_list_users_pagination(client: TestClient, db_session: Session) -> None:
    headers = admin_headers(client, db_session)
    tag = seed_people(db_session)
    url = f"/api/users?q={tag}&sort=name&page_size=2"

    page1 = client.get(url, headers=headers).json()
    assert page1["total"] == 5
    assert page1["page"] == 1
    assert page1["page_size"] == 2
    assert [i["name"].split()[0] for i in page1["items"]] == ["Alice", "Bob"]

    page2 = client.get(url + "&page=2", headers=headers).json()
    assert [i["name"].split()[0] for i in page2["items"]] == ["Carla", "Dan"]

    page3 = client.get(url + "&page=3", headers=headers).json()
    assert [i["name"].split()[0] for i in page3["items"]] == ["Eve"]

    beyond = client.get(url + "&page=9", headers=headers).json()
    assert beyond["items"] == []
    assert beyond["total"] == 5


def test_list_users_pagination_limits(client: TestClient, db_session: Session) -> None:
    headers = admin_headers(client, db_session)
    for query in ("page=0", "page_size=0", "page_size=101", "page=abc"):
        response = client.get(f"/api/users?{query}", headers=headers)
        assert response.status_code == 422, query
    assert client.get("/api/users?page_size=100", headers=headers).status_code == 200


def test_list_users_sorting(client: TestClient, db_session: Session) -> None:
    headers = admin_headers(client, db_session)
    tag = seed_people(db_session)
    base = f"/api/users?q={tag}"

    asc = client.get(f"{base}&sort=name", headers=headers)
    assert names(asc) == ["Alice", "Bob", "Carla", "Dan", "Eve"]
    desc = client.get(f"{base}&sort=-name", headers=headers)
    assert names(desc) == ["Eve", "Dan", "Carla", "Bob", "Alice"]

    by_email = client.get(f"{base}&sort=-email", headers=headers)
    assert names(by_email) == ["Eve", "Dan", "Carla", "Bob", "Alice"]

    oldest = client.get(f"{base}&sort=created_at", headers=headers)
    assert names(oldest) == ["Carla", "Alice", "Eve", "Bob", "Dan"]
    newest = client.get(f"{base}&sort=-created_at", headers=headers)
    assert names(newest) == ["Dan", "Bob", "Eve", "Alice", "Carla"]


def test_list_users_rejects_unknown_sort_field(
    client: TestClient, db_session: Session
) -> None:
    headers = admin_headers(client, db_session)
    for sort in ("password_hash", "-role", "bogus", ""):
        response = client.get("/api/users", headers=headers, params={"sort": sort})
        assert response.status_code == 422, sort
    assert (
        "Allowed fields"
        in client.get("/api/users?sort=bogus", headers=headers).json()["detail"]
    )


def test_list_users_filters(client: TestClient, db_session: Session) -> None:
    headers = admin_headers(client, db_session)
    tag = seed_people(db_session)
    base = f"/api/users?q={tag}&sort=name"

    viewers = client.get(f"{base}&role=viewer", headers=headers)
    assert names(viewers) == ["Bob", "Eve"]
    assert viewers.json()["total"] == 2

    inactive = client.get(f"{base}&is_active=false", headers=headers)
    assert names(inactive) == ["Alice"]
    active_surveyors = client.get(
        f"{base}&role=surveyor&is_active=true", headers=headers
    )
    assert names(active_surveyors) == ["Carla"]

    by_name = client.get(f"/api/users?q=ALICE%20{tag}", headers=headers)
    assert names(by_name) == ["Alice"]
    by_email = client.get(f"/api/users?q=eve.{tag}@", headers=headers)
    assert names(by_email) == ["Eve"]

    assert client.get(f"{base}&role=boss", headers=headers).status_code == 422


def test_list_users_q_treats_wildcards_literally(
    client: TestClient, db_session: Session
) -> None:
    headers = admin_headers(client, db_session)
    seed_people(db_session)
    for q in ("%", "_", "\\"):
        body = client.get("/api/users", headers=headers, params={"q": q}).json()
        assert body["total"] == 0, q


# --- get / patch / delete ---------------------------------------------------


def test_get_user_by_id(client: TestClient, db_session: Session) -> None:
    headers = admin_headers(client, db_session)
    target = make_user(db_session, name="Target")
    response = client.get(f"/api/users/{target.id}", headers=headers)
    assert response.status_code == 200
    assert response.json()["email"] == target.email
    assert client.get(f"/api/users/{uuid.uuid4()}", headers=headers).status_code == 404
    assert client.get("/api/users/not-a-uuid", headers=headers).status_code == 422


def test_admin_updates_role_and_active(client: TestClient, db_session: Session) -> None:
    headers = admin_headers(client, db_session)
    target = make_user(db_session)
    url = f"/api/users/{target.id}"

    promoted = client.patch(url, headers=headers, json={"role": "viewer"})
    assert promoted.status_code == 200
    assert promoted.json()["role"] == "viewer"
    assert promoted.json()["is_active"] is True

    disabled = client.patch(url, headers=headers, json={"is_active": False})
    assert disabled.json()["is_active"] is False
    assert disabled.json()["role"] == "viewer"

    assert client.patch(url, headers=headers, json={"role": "boss"}).status_code == 422
    assert client.patch(url, headers=headers, json={"role": None}).status_code == 422
    missing = client.patch(f"/api/users/{uuid.uuid4()}", headers=headers, json={})
    assert missing.status_code == 404


def test_deactivated_user_cannot_use_old_token(
    client: TestClient, db_session: Session
) -> None:
    headers = admin_headers(client, db_session)
    target = make_user(db_session)
    target_headers = auth_headers(client, target)
    client.patch(f"/api/users/{target.id}", headers=headers, json={"is_active": False})
    assert client.get("/api/auth/me", headers=target_headers).status_code == 401


def test_admin_deletes_user(client: TestClient, db_session: Session) -> None:
    headers = admin_headers(client, db_session)
    target = make_user(db_session)
    assert client.delete(f"/api/users/{target.id}", headers=headers).status_code == 204
    assert client.get(f"/api/users/{target.id}", headers=headers).status_code == 404
    assert client.delete(f"/api/users/{target.id}", headers=headers).status_code == 404


def test_cannot_remove_last_active_admin(
    client: TestClient, db_session: Session
) -> None:
    clear_admins(db_session)
    admin = make_user(db_session, role=UserRole.ADMIN)
    headers = auth_headers(client, admin)
    url = f"/api/users/{admin.id}"

    assert (
        client.patch(url, headers=headers, json={"role": "viewer"}).status_code == 409
    )
    assert (
        client.patch(url, headers=headers, json={"is_active": False}).status_code == 409
    )
    assert client.delete(url, headers=headers).status_code == 409
    # Setting the same role is fine.
    assert client.patch(url, headers=headers, json={"role": "admin"}).status_code == 200

    other = make_user(db_session, role=UserRole.ADMIN)
    assert (
        client.patch(url, headers=headers, json={"role": "viewer"}).status_code == 200
    )
    # Now `other` is the last admin.
    other_headers = auth_headers(client, other)
    other_url = f"/api/users/{other.id}"
    assert client.delete(other_url, headers=other_headers).status_code == 409
