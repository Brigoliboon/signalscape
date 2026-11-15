import uuid
from datetime import UTC, datetime, timedelta

import jwt
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.models.user import User, UserRole
from tests.helpers import PASSWORD, auth_headers, clear_admins, login, make_user


def register(client: TestClient, **overrides: str) -> object:
    body = {
        "email": f"{uuid.uuid4().hex[:12]}@example.com",
        "name": "Ana Reyes",
        "password": PASSWORD,
    }
    body.update(overrides)
    return client.post("/api/auth/register", json=body)


# --- register ---------------------------------------------------------------


def test_register_creates_surveyor(client: TestClient, db_session: Session) -> None:
    response = register(client, email="Ana@Example.com", name="  Ana Reyes ")
    assert response.status_code == 201
    body = response.json()
    assert body["email"] == "ana@example.com"
    assert body["name"] == "Ana Reyes"
    assert body["role"] == "surveyor"
    assert body["is_active"] is True
    assert body["consented_at"] is None
    assert body["good_threshold_dbm"] == -67
    assert body["dead_threshold_dbm"] == -80
    assert "password" not in body
    assert "password_hash" not in body

    stored = db_session.scalar(select(User).where(User.email == "ana@example.com"))
    assert stored is not None
    assert stored.password_hash != PASSWORD


def test_register_cannot_choose_role(client: TestClient) -> None:
    response = register(client, role="admin")
    assert response.status_code == 201
    assert response.json()["role"] == "surveyor"


def test_register_duplicate_email_is_case_insensitive(client: TestClient) -> None:
    assert register(client, email="dup@example.com").status_code == 201
    response = register(client, email="DUP@example.com")
    assert response.status_code == 409


def test_register_validation(client: TestClient) -> None:
    assert register(client, email="not-an-email").status_code == 422
    assert register(client, password="short").status_code == 422
    assert register(client, password="é" * 40).status_code == 422  # 80 bytes
    assert register(client, name="   ").status_code == 422
    assert register(client, name="").status_code == 422


# --- login ------------------------------------------------------------------


def test_login_returns_token(client: TestClient, db_session: Session) -> None:
    user = make_user(db_session, role=UserRole.VIEWER, email="v@example.com")
    response = client.post(
        "/api/auth/login", data={"username": "V@Example.com", "password": PASSWORD}
    )
    assert response.status_code == 200
    body = response.json()
    assert body["token_type"] == "bearer"
    assert body["expires_in"] == 24 * 60 * 60

    settings = get_settings()
    claims = jwt.decode(
        body["access_token"], settings.jwt_secret, algorithms=[settings.jwt_algorithm]
    )
    assert claims["sub"] == str(user.id)
    assert claims["role"] == "viewer"


def test_login_rejects_bad_credentials(client: TestClient, db_session: Session) -> None:
    user = make_user(db_session)
    wrong = client.post(
        "/api/auth/login", data={"username": user.email, "password": "nope-nope"}
    )
    unknown = client.post(
        "/api/auth/login", data={"username": "ghost@example.com", "password": "x"}
    )
    assert wrong.status_code == unknown.status_code == 401
    assert wrong.json() == unknown.json()
    assert wrong.headers["www-authenticate"] == "Bearer"


def test_login_rejects_inactive_user(client: TestClient, db_session: Session) -> None:
    user = make_user(db_session, is_active=False)
    response = client.post(
        "/api/auth/login", data={"username": user.email, "password": PASSWORD}
    )
    assert response.status_code == 401


# --- get_current_user -------------------------------------------------------


def test_me_requires_valid_token(client: TestClient, db_session: Session) -> None:
    assert client.get("/api/auth/me").status_code == 401
    bad = {"Authorization": "Bearer not-a-jwt"}
    assert client.get("/api/auth/me", headers=bad).status_code == 401

    settings = get_settings()
    for claims in (
        {"sub": "not-a-uuid", "exp": datetime.now(UTC) + timedelta(hours=1)},
        {"sub": str(uuid.uuid4()), "exp": datetime.now(UTC) + timedelta(hours=1)},
        {"sub": str(make_user(db_session).id), "exp": datetime.now(UTC)},
    ):
        token = jwt.encode(claims, settings.jwt_secret, algorithm="HS256")
        response = client.get(
            "/api/auth/me", headers={"Authorization": f"Bearer {token}"}
        )
        assert response.status_code == 401, claims


def test_token_stops_working_when_user_deactivated(
    client: TestClient, db_session: Session
) -> None:
    user = make_user(db_session)
    headers = auth_headers(client, user)
    assert client.get("/api/auth/me", headers=headers).status_code == 200
    user.is_active = False
    db_session.commit()
    assert client.get("/api/auth/me", headers=headers).status_code == 401


def test_me_returns_profile(client: TestClient, db_session: Session) -> None:
    user = make_user(db_session, name="Pat")
    response = client.get("/api/auth/me", headers=auth_headers(client, user))
    assert response.status_code == 200
    assert response.json()["id"] == str(user.id)
    assert response.json()["name"] == "Pat"


# --- PATCH /auth/me ---------------------------------------------------------


def test_update_name_and_thresholds(client: TestClient, db_session: Session) -> None:
    headers = auth_headers(client, make_user(db_session))
    response = client.patch(
        "/api/auth/me",
        headers=headers,
        json={
            "name": " New Name ",
            "good_threshold_dbm": -60,
            "dead_threshold_dbm": -75,
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["name"] == "New Name"
    assert body["good_threshold_dbm"] == -60
    assert body["dead_threshold_dbm"] == -75


def test_update_single_threshold_is_checked_against_stored_value(
    client: TestClient, db_session: Session
) -> None:
    headers = auth_headers(client, make_user(db_session))
    # Stored thresholds are -67 (good) and -80 (dead).
    too_high_dead = client.patch(
        "/api/auth/me", headers=headers, json={"dead_threshold_dbm": -60}
    )
    assert too_high_dead.status_code == 422
    too_low_good = client.patch(
        "/api/auth/me", headers=headers, json={"good_threshold_dbm": -85}
    )
    assert too_low_good.status_code == 422
    ok = client.patch("/api/auth/me", headers=headers, json={"dead_threshold_dbm": -90})
    assert ok.status_code == 200
    assert ok.json()["dead_threshold_dbm"] == -90
    assert ok.json()["good_threshold_dbm"] == -67


def test_threshold_validation(client: TestClient, db_session: Session) -> None:
    headers = auth_headers(client, make_user(db_session))

    def patch(body: dict) -> int:
        return client.patch("/api/auth/me", headers=headers, json=body).status_code

    assert patch({"good_threshold_dbm": -70, "dead_threshold_dbm": -70}) == 422
    assert patch({"good_threshold_dbm": -80, "dead_threshold_dbm": -60}) == 422
    assert patch({"good_threshold_dbm": 5}) == 422
    assert patch({"dead_threshold_dbm": -121}) == 422
    assert patch({"name": None}) == 422
    assert patch({"name": "   "}) == 422
    # Nothing was saved by the failed requests.
    profile = client.get("/api/auth/me", headers=headers).json()
    assert (profile["good_threshold_dbm"], profile["dead_threshold_dbm"]) == (-67, -80)


def test_change_password(client: TestClient, db_session: Session) -> None:
    user = make_user(db_session, email="pw@example.com")
    headers = auth_headers(client, user)

    missing_current = client.patch(
        "/api/auth/me", headers=headers, json={"password": "brand-new-pass"}
    )
    assert missing_current.status_code == 422

    wrong_current = client.patch(
        "/api/auth/me",
        headers=headers,
        json={"password": "brand-new-pass", "current_password": "wrong-wrong"},
    )
    assert wrong_current.status_code == 400

    too_short = client.patch(
        "/api/auth/me",
        headers=headers,
        json={"password": "short", "current_password": PASSWORD},
    )
    assert too_short.status_code == 422

    changed = client.patch(
        "/api/auth/me",
        headers=headers,
        json={"password": "brand-new-pass", "current_password": PASSWORD},
    )
    assert changed.status_code == 200

    old = client.post(
        "/api/auth/login", data={"username": user.email, "password": PASSWORD}
    )
    assert old.status_code == 401
    assert login(client, user.email, "brand-new-pass")


def test_update_requires_auth(client: TestClient) -> None:
    assert client.patch("/api/auth/me", json={"name": "x"}).status_code == 401


# --- consent ----------------------------------------------------------------


def test_consent_is_recorded_once(client: TestClient, db_session: Session) -> None:
    headers = auth_headers(client, make_user(db_session))
    first = client.post("/api/auth/me/consent", headers=headers)
    assert first.status_code == 200
    stamp = first.json()["consented_at"]
    assert stamp is not None
    second = client.post("/api/auth/me/consent", headers=headers)
    assert second.json()["consented_at"] == stamp
    assert client.get("/api/auth/me", headers=headers).json()["consented_at"] == stamp


def test_consent_requires_auth(client: TestClient) -> None:
    assert client.post("/api/auth/me/consent").status_code == 401


# --- DELETE /auth/me --------------------------------------------------------


def test_delete_own_account(client: TestClient, db_session: Session) -> None:
    user = make_user(db_session)
    headers = auth_headers(client, user)
    assert client.delete("/api/auth/me", headers=headers).status_code == 204
    assert client.get("/api/auth/me", headers=headers).status_code == 401
    assert db_session.get(User, user.id) is None


def test_last_admin_cannot_delete_self(client: TestClient, db_session: Session) -> None:
    clear_admins(db_session)
    admin = make_user(db_session, role=UserRole.ADMIN)
    headers = auth_headers(client, admin)
    assert client.delete("/api/auth/me", headers=headers).status_code == 409

    make_user(db_session, role=UserRole.ADMIN)
    assert client.delete("/api/auth/me", headers=headers).status_code == 204
