import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models.building import Building, Floor
from app.models.survey import Checkpoint, ScanReading, Survey, SurveyStatus
from app.models.user import User, UserRole
from tests.helpers import (
    auth_headers,
    make_building,
    make_floor,
    make_survey,
    make_user,
)

Headers = dict[str, str]


def survey_payload(building: Building, **overrides) -> dict:
    payload = {
        "building_id": str(building.id),
        "device_model": "Pixel 7",
        "has_barometer": True,
        "origin_lat": 14.5995,
        "origin_lng": 120.9842,
        "origin_accuracy_m": 6.5,
    }
    payload.update(overrides)
    return payload


def reading(floor: Floor, **overrides) -> dict:
    item = {
        "client_id": str(uuid.uuid4()),
        "floor_id": str(floor.id),
        "lat": 14.59951,
        "lng": 120.98421,
        "accuracy_m": 2.5,
        "bssid": "AA:BB:CC:DD:EE:01",
        "ssid": "CISC-WiFi",
        "rssi_dbm": -61,
        "frequency_mhz": 2437,
        "scanned_at": "2026-11-15T10:00:00+08:00",
    }
    item.update(overrides)
    return item


def checkpoint(floor: Floor, **overrides) -> dict:
    item = {
        "client_id": str(uuid.uuid4()),
        "floor_id": str(floor.id),
        "lat": 14.59960,
        "lng": 120.98430,
        "estimated_lat": 14.59962,
        "estimated_lng": 120.98433,
        "source": "tap",
        "recorded_at": "2026-11-15T10:05:00+08:00",
    }
    item.update(overrides)
    return item


class World:
    """A surveyor with a consented account, one building, one floor, one survey."""

    def __init__(self, client: TestClient, db: Session) -> None:
        self.client = client
        self.db = db
        self.owner = make_user(db, consented=True)
        self.headers = auth_headers(client, self.owner)
        self.building = make_building(db, self.owner)
        self.floor = make_floor(db, self.building)
        self.survey = make_survey(db, self.building, self.owner)

    @property
    def url(self) -> str:
        return f"/api/surveys/{self.survey.id}"

    def headers_for(self, user: User) -> Headers:
        return auth_headers(self.client, user)


@pytest.fixture
def world(client: TestClient, db_session: Session) -> World:
    return World(client, db_session)


def set_status(db: Session, survey: Survey, status: SurveyStatus) -> None:
    survey.status = status
    db.commit()


# --- login and roles --------------------------------------------------------


def test_survey_endpoints_require_login(client: TestClient) -> None:
    sid = uuid.uuid4()
    base = f"/api/surveys/{sid}"
    assert client.get("/api/surveys").status_code == 401
    assert client.post("/api/surveys", json={}).status_code == 401
    assert client.get(base).status_code == 401
    assert client.patch(base, json={}).status_code == 401
    assert client.delete(base).status_code == 401
    for suffix in ("readings", "checkpoints", "shares"):
        assert client.get(f"{base}/{suffix}").status_code == 401
        assert client.post(f"{base}/{suffix}", json={}).status_code == 401
    assert client.delete(f"{base}/shares/{uuid.uuid4()}").status_code == 401


def test_viewer_cannot_write(world: World) -> None:
    viewer = make_user(world.db, role=UserRole.VIEWER)
    headers = world.headers_for(viewer)
    base = world.url
    assert (
        world.client.post(
            "/api/surveys", headers=headers, json=survey_payload(world.building)
        ).status_code
        == 403
    )
    assert world.client.patch(base, headers=headers, json={}).status_code == 403
    assert world.client.delete(base, headers=headers).status_code == 403
    for suffix in ("readings", "checkpoints", "shares"):
        assert (
            world.client.post(f"{base}/{suffix}", headers=headers, json={}).status_code
            == 403
        )
    assert world.client.get(f"{base}/shares", headers=headers).status_code == 403
    gone = world.client.delete(f"{base}/shares/{viewer.id}", headers=headers)
    assert gone.status_code == 403


# --- create -----------------------------------------------------------------


def test_create_survey(world: World) -> None:
    response = world.client.post(
        "/api/surveys",
        headers=world.headers,
        json=survey_payload(world.building, notes="  ground floor first  "),
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["status"] == "active"
    assert body["building_id"] == str(world.building.id)
    assert body["surveyor_id"] == str(world.owner.id)
    assert body["started_at"]
    assert body["ended_at"] is None
    assert body["origin_accuracy_m"] == 6.5
    assert body["step_length_m"] == 0.7
    assert body["has_barometer"] is True
    assert body["notes"] == "ground floor first"
    assert body["processed_at"] is None


def test_create_survey_blank_text_becomes_null(world: World) -> None:
    response = world.client.post(
        "/api/surveys",
        headers=world.headers,
        json=survey_payload(world.building, notes="  ", device_model=None),
    )
    assert response.status_code == 201
    assert response.json()["notes"] is None
    assert response.json()["device_model"] is None


def test_create_survey_needs_consent(client: TestClient, db_session: Session) -> None:
    surveyor = make_user(db_session)
    building = make_building(db_session, surveyor)
    response = client.post(
        "/api/surveys",
        headers=auth_headers(client, surveyor),
        json=survey_payload(building),
    )
    assert response.status_code == 403
    assert "consent" in response.json()["detail"].lower()
    assert db_session.scalar(select(func.count()).select_from(Survey)) == 0
    consent = client.post(
        "/api/auth/me/consent", headers=auth_headers(client, surveyor)
    )
    assert consent.status_code == 200
    again = client.post(
        "/api/surveys",
        headers=auth_headers(client, surveyor),
        json=survey_payload(building),
    )
    assert again.status_code == 201


def test_admin_can_create_without_consent(
    client: TestClient, db_session: Session
) -> None:
    admin = make_user(db_session, role=UserRole.ADMIN)
    building = make_building(db_session, make_user(db_session))
    response = client.post(
        "/api/surveys",
        headers=auth_headers(client, admin),
        json=survey_payload(building),
    )
    assert response.status_code == 201
    assert response.json()["surveyor_id"] == str(admin.id)


def test_create_survey_in_unseen_building_is_404(world: World) -> None:
    other = make_building(world.db, make_user(world.db, consented=True))
    response = world.client.post(
        "/api/surveys", headers=world.headers, json=survey_payload(other)
    )
    assert response.status_code == 404
    missing = world.client.post(
        "/api/surveys",
        headers=world.headers,
        json=survey_payload(world.building, building_id=str(uuid.uuid4())),
    )
    assert missing.status_code == 404


@pytest.mark.parametrize(
    "changes",
    [
        {"origin_accuracy_m": 10.5},
        {"origin_accuracy_m": -1},
        {"origin_lat": 91},
        {"origin_lat": -91},
        {"origin_lng": 181},
        {"origin_lng": -181},
        {"step_length_m": 0},
        {"step_length_m": 10},
        {"building_id": "not-a-uuid"},
        {"device_model": "x" * 201},
        {"notes": "x" * 2001},
    ],
)
def test_create_survey_validation(world: World, changes: dict) -> None:
    response = world.client.post(
        "/api/surveys",
        headers=world.headers,
        json=survey_payload(world.building, **changes),
    )
    assert response.status_code == 422


def test_create_survey_accepts_boundary_accuracy(world: World) -> None:
    response = world.client.post(
        "/api/surveys",
        headers=world.headers,
        json=survey_payload(world.building, origin_accuracy_m=10, step_length_m=0.65),
    )
    assert response.status_code == 201
    assert response.json()["step_length_m"] == 0.65


def test_create_survey_requires_origin_fix(world: World) -> None:
    payload = survey_payload(world.building)
    del payload["origin_accuracy_m"]
    response = world.client.post("/api/surveys", headers=world.headers, json=payload)
    assert response.status_code == 422


# --- visibility, get, list --------------------------------------------------


def test_surveyor_sees_only_own_surveys(world: World) -> None:
    other_user = make_user(world.db, consented=True)
    other = make_survey(world.db, make_building(world.db, other_user), other_user)
    headers = world.headers_for(other_user)
    assert world.client.get(world.url, headers=headers).status_code == 404
    assert (
        world.client.get(f"/api/surveys/{other.id}", headers=headers).status_code == 200
    )
    listing = world.client.get("/api/surveys", headers=world.headers)
    assert [s["id"] for s in listing.json()["items"]] == [str(world.survey.id)]
    # every nested route hides it too, and writes are 404 not 403
    for suffix in ("readings", "checkpoints"):
        assert (
            world.client.get(f"{world.url}/{suffix}", headers=headers).status_code
            == 404
        )
    assert world.client.patch(world.url, headers=headers, json={}).status_code == 404
    assert world.client.delete(world.url, headers=headers).status_code == 404
    batch = world.client.post(
        f"{world.url}/readings",
        headers=headers,
        json={"readings": [reading(world.floor)]},
    )
    assert batch.status_code == 404
    assert (
        world.client.get(f"/api/surveys/{uuid.uuid4()}", headers=headers).status_code
        == 404
    )


def test_admin_sees_every_survey(world: World) -> None:
    admin = make_user(world.db, role=UserRole.ADMIN)
    headers = world.headers_for(admin)
    assert world.client.get(world.url, headers=headers).status_code == 200
    listing = world.client.get("/api/surveys", headers=headers)
    assert listing.json()["total"] >= 1
    assert str(world.survey.id) in [s["id"] for s in listing.json()["items"]]
    mine = world.client.get(
        f"/api/surveys?surveyor_id={world.owner.id}", headers=headers
    )
    assert [s["id"] for s in mine.json()["items"]] == [str(world.survey.id)]
    nobody = world.client.get(
        f"/api/surveys?surveyor_id={uuid.uuid4()}", headers=headers
    )
    assert nobody.json()["total"] == 0


def test_survey_responses_include_the_surveyor_name(world: World) -> None:
    detail = world.client.get(world.url, headers=world.headers)
    assert detail.status_code == 200
    assert detail.json()["surveyor_name"] == world.owner.name

    listing = world.client.get("/api/surveys", headers=world.headers)
    item = next(s for s in listing.json()["items"] if s["id"] == str(world.survey.id))
    assert item["surveyor_name"] == world.owner.name


def test_surveyor_cannot_filter_by_surveyor(world: World) -> None:
    response = world.client.get(
        f"/api/surveys?surveyor_id={world.owner.id}", headers=world.headers
    )
    assert response.status_code == 403


def test_viewer_sees_only_shared_surveys(world: World) -> None:
    viewer = make_user(world.db, role=UserRole.VIEWER)
    headers = world.headers_for(viewer)
    second = make_survey(world.db, world.building, world.owner)
    assert world.client.get("/api/surveys", headers=headers).json()["total"] == 0
    assert world.client.get(world.url, headers=headers).status_code == 404

    shared = world.client.post(
        f"{world.url}/shares", headers=world.headers, json={"email": viewer.email}
    )
    assert shared.status_code == 201
    listing = world.client.get("/api/surveys", headers=headers).json()
    assert [s["id"] for s in listing["items"]] == [str(world.survey.id)]
    assert world.client.get(world.url, headers=headers).status_code == 200
    assert (
        world.client.get(f"/api/surveys/{second.id}", headers=headers).status_code
        == 404
    )
    assert world.client.get(f"{world.url}/readings", headers=headers).status_code == 200
    assert (
        world.client.get(f"{world.url}/checkpoints", headers=headers).status_code == 200
    )

    revoked = world.client.delete(
        f"{world.url}/shares/{viewer.id}", headers=world.headers
    )
    assert revoked.status_code == 204
    assert world.client.get(world.url, headers=headers).status_code == 404


def test_list_filters(world: World) -> None:
    other_building = make_building(world.db, world.owner)
    now = datetime.now(UTC)
    old = make_survey(
        world.db,
        other_building,
        world.owner,
        status=SurveyStatus.COMPLETED,
        started_at=now - timedelta(days=10),
    )
    get = lambda query: world.client.get(  # noqa: E731
        f"/api/surveys?{query}", headers=world.headers
    ).json()

    assert get("")["total"] == 2
    assert [s["id"] for s in get(f"building_id={other_building.id}")["items"]] == [
        str(old.id)
    ]
    assert [s["id"] for s in get("status=completed")["items"]] == [str(old.id)]
    assert [s["id"] for s in get("status=active")["items"]] == [str(world.survey.id)]
    cutoff = (now - timedelta(days=5)).isoformat().replace("+00:00", "Z")
    assert [s["id"] for s in get(f"from={cutoff}")["items"]] == [str(world.survey.id)]
    assert [s["id"] for s in get(f"to={cutoff}")["items"]] == [str(old.id)]


def test_list_rejects_bad_filters(world: World) -> None:
    for query in ("status=bogus", "from=2026-11-15T10:00:00", "to=yesterday"):
        response = world.client.get(f"/api/surveys?{query}", headers=world.headers)
        assert response.status_code == 422, query


def test_list_sorting_and_paging(world: World) -> None:
    now = datetime.now(UTC)
    older = make_survey(
        world.db,
        world.building,
        world.owner,
        status=SurveyStatus.PAUSED,
        started_at=now - timedelta(days=1),
    )
    base = "/api/surveys"
    default = world.client.get(base, headers=world.headers).json()
    # newest first by default
    assert [s["id"] for s in default["items"]] == [str(world.survey.id), str(older.id)]
    asc = world.client.get(f"{base}?sort=started_at", headers=world.headers).json()
    assert [s["id"] for s in asc["items"]] == [str(older.id), str(world.survey.id)]
    by_status = world.client.get(f"{base}?sort=-status", headers=world.headers).json()
    assert by_status["items"][0]["status"] == "paused"
    page = world.client.get(f"{base}?page=2&page_size=1", headers=world.headers).json()
    assert page["total"] == 2
    assert page["page"] == 2
    assert len(page["items"]) == 1
    bad = world.client.get(f"{base}?sort=notes", headers=world.headers)
    assert bad.status_code == 422


# --- status changes ---------------------------------------------------------


def patch(world: World, body: dict, headers: Headers | None = None):
    return world.client.patch(world.url, headers=headers or world.headers, json=body)


def test_pause_resume_and_complete(world: World) -> None:
    paused = patch(world, {"status": "paused"})
    assert paused.status_code == 200
    assert paused.json()["status"] == "paused"
    assert paused.json()["ended_at"] is None
    resumed = patch(world, {"status": "active"})
    assert resumed.json()["status"] == "active"
    done = patch(world, {"status": "completed"})
    assert done.status_code == 200
    assert done.json()["status"] == "completed"
    assert done.json()["ended_at"] is not None


def test_complete_from_paused(world: World) -> None:
    set_status(world.db, world.survey, SurveyStatus.PAUSED)
    done = patch(world, {"status": "completed"})
    assert done.status_code == 200
    assert done.json()["ended_at"] is not None


def test_completed_is_final(world: World) -> None:
    done = patch(world, {"status": "completed"})
    ended_at = done.json()["ended_at"]
    for target in ("active", "paused"):
        response = patch(world, {"status": target})
        assert response.status_code == 409, target
    # repeating the same request is a no-op, not an error, and keeps ended_at
    again = patch(world, {"status": "completed"})
    assert again.status_code == 200
    assert again.json()["ended_at"] == ended_at
    # notes can still be edited
    noted = patch(world, {"notes": "final"})
    assert noted.status_code == 200
    assert noted.json()["notes"] == "final"
    assert noted.json()["status"] == "completed"


def test_processed_survey_cannot_change_status(world: World) -> None:
    set_status(world.db, world.survey, SurveyStatus.PROCESSED)
    for target in ("active", "paused", "completed"):
        assert patch(world, {"status": target}).status_code == 409


def test_repeating_current_status_is_accepted(world: World) -> None:
    assert patch(world, {"status": "active"}).json()["status"] == "active"
    patch(world, {"status": "paused"})
    assert patch(world, {"status": "paused"}).json()["status"] == "paused"


def test_status_validation(world: World) -> None:
    assert patch(world, {"status": "processed"}).status_code == 422
    assert patch(world, {"status": "ended"}).status_code == 422
    assert patch(world, {"status": None}).status_code == 422
    assert patch(world, {"notes": "x" * 2001}).status_code == 422
    world.db.refresh(world.survey)
    assert world.survey.status == SurveyStatus.ACTIVE


def test_patch_notes_only(world: World) -> None:
    response = patch(world, {"notes": "  east wing is slow  "})
    assert response.status_code == 200
    assert response.json()["notes"] == "east wing is slow"
    assert response.json()["status"] == "active"
    cleared = patch(world, {"notes": None})
    assert cleared.json()["notes"] is None
    assert patch(world, {}).status_code == 200


def test_admin_can_change_any_survey(world: World) -> None:
    admin = make_user(world.db, role=UserRole.ADMIN)
    response = patch(world, {"status": "paused"}, world.headers_for(admin))
    assert response.status_code == 200


# --- delete -----------------------------------------------------------------


def test_delete_survey_removes_its_data(world: World) -> None:
    world.client.post(
        f"{world.url}/readings",
        headers=world.headers,
        json={"readings": [reading(world.floor)]},
    )
    world.client.post(
        f"{world.url}/checkpoints",
        headers=world.headers,
        json={"checkpoints": [checkpoint(world.floor)]},
    )
    response = world.client.delete(world.url, headers=world.headers)
    assert response.status_code == 204
    assert world.client.get(world.url, headers=world.headers).status_code == 404
    assert world.db.scalar(select(func.count()).select_from(ScanReading)) == 0
    assert world.db.scalar(select(func.count()).select_from(Checkpoint)) == 0


def test_deleting_building_floor_or_account_cascades(world: World) -> None:
    world.client.post(
        f"{world.url}/readings",
        headers=world.headers,
        json={"readings": [reading(world.floor)]},
    )
    # deleting the floor removes its readings but keeps the survey
    assert (
        world.client.delete(
            f"/api/floors/{world.floor.id}", headers=world.headers
        ).status_code
        == 204
    )
    assert world.db.scalar(select(func.count()).select_from(ScanReading)) == 0
    assert world.client.get(world.url, headers=world.headers).status_code == 200
    # deleting the account removes the survey
    assert world.client.delete("/api/auth/me", headers=world.headers).status_code == 204
    assert world.db.scalar(select(func.count()).select_from(Survey)) == 0


def test_deleting_building_removes_surveys(world: World) -> None:
    response = world.client.delete(
        f"/api/buildings/{world.building.id}", headers=world.headers
    )
    assert response.status_code == 204
    assert world.db.scalar(select(func.count()).select_from(Survey)) == 0


# --- readings ---------------------------------------------------------------


def upload(world: World, readings: list[dict], headers: Headers | None = None):
    return world.client.post(
        f"{world.url}/readings",
        headers=headers or world.headers,
        json={"readings": readings},
    )


def test_upload_readings(world: World) -> None:
    items = [reading(world.floor, rssi_dbm=-50 - i) for i in range(3)]
    response = upload(world, items)
    assert response.status_code == 200, response.text
    assert response.json() == {"inserted": 3, "skipped": 0}
    stored = world.db.scalars(select(ScanReading).order_by(ScanReading.id)).all()
    assert len(stored) == 3
    assert stored[0].bssid == "aa:bb:cc:dd:ee:01"
    assert stored[0].survey_id == world.survey.id
    assert stored[0].client_id == uuid.UUID(items[0]["client_id"])


def test_reupload_is_idempotent(world: World) -> None:
    first = [reading(world.floor) for _ in range(3)]
    assert upload(world, first).json() == {"inserted": 3, "skipped": 0}
    extra = reading(world.floor)
    again = upload(world, [*first, extra])
    assert again.status_code == 200
    assert again.json() == {"inserted": 1, "skipped": 3}
    assert upload(world, first).json() == {"inserted": 0, "skipped": 3}
    count = world.db.scalar(select(func.count()).select_from(ScanReading))
    assert count == 4


def test_duplicate_client_id_inside_one_batch(world: World) -> None:
    item = reading(world.floor)
    response = upload(world, [item, dict(item), reading(world.floor)])
    assert response.json() == {"inserted": 2, "skipped": 1}


def test_same_client_id_allowed_in_another_survey(world: World) -> None:
    item = reading(world.floor)
    assert upload(world, [item]).json()["inserted"] == 1
    other = make_survey(world.db, world.building, world.owner)
    response = world.client.post(
        f"/api/surveys/{other.id}/readings",
        headers=world.headers,
        json={"readings": [item]},
    )
    assert response.json() == {"inserted": 1, "skipped": 0}


def test_readings_accepted_while_paused_only_until_completed(world: World) -> None:
    set_status(world.db, world.survey, SurveyStatus.PAUSED)
    assert upload(world, [reading(world.floor)]).status_code == 200
    for status in (SurveyStatus.COMPLETED, SurveyStatus.PROCESSED):
        set_status(world.db, world.survey, status)
        response = upload(world, [reading(world.floor)])
        assert response.status_code == 409, status
    assert world.db.scalar(select(func.count()).select_from(ScanReading)) == 1


def test_readings_must_use_floors_of_the_surveys_building(world: World) -> None:
    other_building = make_building(world.db, world.owner)
    foreign_floor = make_floor(world.db, other_building)
    response = upload(world, [reading(world.floor), reading(foreign_floor)])
    assert response.status_code == 422
    assert str(foreign_floor.id) in response.json()["detail"]
    assert world.db.scalar(select(func.count()).select_from(ScanReading)) == 0
    unknown = upload(world, [reading(world.floor, floor_id=str(uuid.uuid4()))])
    assert unknown.status_code == 422


def test_batch_size_limits(world: World) -> None:
    assert upload(world, []).status_code == 422
    too_many = [reading(world.floor) for _ in range(1001)]
    assert upload(world, too_many).status_code == 422
    assert world.db.scalar(select(func.count()).select_from(ScanReading)) == 0
    full = [reading(world.floor) for _ in range(1000)]
    response = upload(world, full)
    assert response.status_code == 200
    assert response.json()["inserted"] == 1000


@pytest.mark.parametrize(
    "changes",
    [
        {"rssi_dbm": 1},
        {"rssi_dbm": -121},
        {"rssi_dbm": "strong"},
        {"lat": 90.5},
        {"lng": -180.5},
        {"accuracy_m": -1},
        {"accuracy_m": 5000},
        {"bssid": "not-a-mac"},
        {"bssid": "aa:bb:cc:dd:ee"},
        {"bssid": "aa:bb:cc:dd:ee:gg"},
        {"bssid": "aa:bb-cc:dd:ee:ff"},
        {"frequency_mhz": 100},
        {"frequency_mhz": 9000},
        {"ssid": "x" * 33},
        {"ssid": "bad\u0000name"},
        {"scanned_at": "2026-11-15T10:00:00"},
        {"scanned_at": "yesterday"},
        {"client_id": "nope"},
        {"floor_id": "nope"},
    ],
)
def test_reading_validation(world: World, changes: dict) -> None:
    response = upload(world, [reading(world.floor, **changes)])
    assert response.status_code == 422
    assert world.db.scalar(select(func.count()).select_from(ScanReading)) == 0


def test_reading_boundaries_and_normalization(world: World) -> None:
    items = [
        reading(world.floor, rssi_dbm=-120, bssid="AA-BB-CC-DD-EE-02", ssid=""),
        reading(world.floor, rssi_dbm=0, accuracy_m=None, frequency_mhz=5180),
        reading(world.floor, ssid="é" * 16, lat=-90, lng=180),
    ]
    assert upload(world, items).json() == {"inserted": 3, "skipped": 0}
    stored = world.db.scalars(select(ScanReading).order_by(ScanReading.id)).all()
    assert stored[0].bssid == "aa:bb:cc:dd:ee:02"
    assert stored[0].ssid == ""
    assert stored[1].accuracy_m is None


def test_missing_reading_fields_are_rejected(world: World) -> None:
    incomplete = reading(world.floor)
    del incomplete["rssi_dbm"]
    assert upload(world, [incomplete]).status_code == 422
    assert (
        world.client.post(
            f"{world.url}/readings", headers=world.headers, json={}
        ).status_code
        == 422
    )


def test_admin_can_upload_for_any_survey(world: World) -> None:
    admin = make_user(world.db, role=UserRole.ADMIN)
    response = upload(world, [reading(world.floor)], world.headers_for(admin))
    assert response.status_code == 200


def test_list_readings(world: World) -> None:
    second_floor = make_floor(world.db, world.building, level=1)
    upload(
        world,
        [
            reading(world.floor, rssi_dbm=-70, bssid="aa:bb:cc:dd:ee:01"),
            reading(world.floor, rssi_dbm=-50, bssid="aa:bb:cc:dd:ee:02"),
            reading(second_floor, rssi_dbm=-90, bssid="aa:bb:cc:dd:ee:01"),
        ],
    )
    base = f"{world.url}/readings"

    def get(query: str = "") -> dict:
        response = world.client.get(f"{base}?{query}", headers=world.headers)
        assert response.status_code == 200, response.text
        return response.json()

    everything = get()
    assert everything["total"] == 3
    first = everything["items"][0]
    assert first["survey_id"] == str(world.survey.id)
    assert set(first) >= {
        "id",
        "floor_id",
        "client_id",
        "lat",
        "lng",
        "accuracy_m",
        "bssid",
        "ssid",
        "rssi_dbm",
        "frequency_mhz",
        "scanned_at",
    }
    assert get(f"floor_id={second_floor.id}")["total"] == 1
    assert get("bssid=AA:BB:CC:DD:EE:01")["total"] == 2
    assert get("bssid=aa-bb-cc-dd-ee-02")["total"] == 1
    assert get("min_rssi=-75")["total"] == 2
    assert get("min_rssi=-50")["total"] == 1
    strongest = get("sort=-rssi_dbm")
    assert [r["rssi_dbm"] for r in strongest["items"]] == [-50, -70, -90]
    weakest = get("sort=rssi_dbm&page=1&page_size=2")
    assert [r["rssi_dbm"] for r in weakest["items"]] == [-90, -70]
    assert weakest["total"] == 3
    for bad in ("sort=bssid", "bssid=zz", "min_rssi=5", "page_size=101"):
        assert (
            world.client.get(f"{base}?{bad}", headers=world.headers).status_code == 422
        ), bad


def test_reading_order_by_scan_time(world: World) -> None:
    upload(
        world,
        [
            reading(world.floor, scanned_at="2026-11-15T10:00:02+00:00"),
            reading(world.floor, scanned_at="2026-11-15T10:00:01+00:00"),
        ],
    )
    items = world.client.get(f"{world.url}/readings", headers=world.headers).json()[
        "items"
    ]
    assert items[0]["scanned_at"] < items[1]["scanned_at"]


# --- checkpoints ------------------------------------------------------------


def send_checkpoints(world: World, items: list[dict], headers: Headers | None = None):
    return world.client.post(
        f"{world.url}/checkpoints",
        headers=headers or world.headers,
        json={"checkpoints": items},
    )


def test_upload_checkpoints_is_idempotent(world: World) -> None:
    first = [checkpoint(world.floor), checkpoint(world.floor, source="gps")]
    response = send_checkpoints(world, first)
    assert response.status_code == 200, response.text
    assert response.json() == {"inserted": 2, "skipped": 0}
    again = send_checkpoints(world, [*first, checkpoint(world.floor)])
    assert again.json() == {"inserted": 1, "skipped": 2}
    assert world.db.scalar(select(func.count()).select_from(Checkpoint)) == 3


def test_list_checkpoints(world: World) -> None:
    second_floor = make_floor(world.db, world.building, level=1)
    send_checkpoints(
        world,
        [
            checkpoint(world.floor, recorded_at="2026-11-15T10:10:00+00:00"),
            checkpoint(world.floor, recorded_at="2026-11-15T10:05:00+00:00"),
            checkpoint(second_floor, source="gps"),
        ],
    )
    base = f"{world.url}/checkpoints"
    listing = world.client.get(base, headers=world.headers).json()
    assert listing["total"] == 3
    times = [c["recorded_at"] for c in listing["items"]]
    assert times == sorted(times)
    item = listing["items"][0]
    assert set(item) >= {"estimated_lat", "estimated_lng", "source", "client_id"}
    only = world.client.get(f"{base}?floor_id={second_floor.id}", headers=world.headers)
    assert [c["source"] for c in only.json()["items"]] == ["gps"]
    desc = world.client.get(f"{base}?sort=-recorded_at", headers=world.headers)
    assert desc.json()["items"][0]["recorded_at"] == times[-1]
    paged = world.client.get(f"{base}?page_size=2&page=2", headers=world.headers)
    assert len(paged.json()["items"]) == 1


def test_checkpoint_rules(world: World) -> None:
    other_floor = make_floor(world.db, make_building(world.db, world.owner))
    assert send_checkpoints(world, [checkpoint(other_floor)]).status_code == 422
    assert send_checkpoints(world, []).status_code == 422
    assert (
        send_checkpoints(world, [checkpoint(world.floor, source="x")]).status_code
        == 422
    )
    assert (
        send_checkpoints(world, [checkpoint(world.floor, lat=100)]).status_code == 422
    )
    bad_estimate = checkpoint(world.floor, estimated_lng=181)
    assert send_checkpoints(world, [bad_estimate]).status_code == 422
    naive = checkpoint(world.floor, recorded_at="2026-11-15T10:05:00")
    assert send_checkpoints(world, [naive]).status_code == 422
    too_many = [checkpoint(world.floor) for _ in range(1001)]
    assert send_checkpoints(world, too_many).status_code == 422
    set_status(world.db, world.survey, SurveyStatus.COMPLETED)
    assert send_checkpoints(world, [checkpoint(world.floor)]).status_code == 409
    assert world.db.scalar(select(func.count()).select_from(Checkpoint)) == 0


# --- shares -----------------------------------------------------------------


def share(world: World, email: str, headers: Headers | None = None):
    return world.client.post(
        f"{world.url}/shares", headers=headers or world.headers, json={"email": email}
    )


def test_share_lifecycle(world: World) -> None:
    viewer = make_user(world.db, role=UserRole.VIEWER, email="viewer@example.com")
    created = share(world, " Viewer@Example.com ")
    assert created.status_code == 201, created.text
    assert created.json()["user_id"] == str(viewer.id)
    assert created.json()["email"] == "viewer@example.com"
    assert created.json()["survey_id"] == str(world.survey.id)

    duplicate = share(world, "viewer@example.com")
    assert duplicate.status_code == 409

    listing = world.client.get(f"{world.url}/shares", headers=world.headers).json()
    assert listing["total"] == 1
    assert listing["items"][0]["name"] == viewer.name

    gone = world.client.delete(f"{world.url}/shares/{viewer.id}", headers=world.headers)
    assert gone.status_code == 204
    again = world.client.delete(
        f"{world.url}/shares/{viewer.id}", headers=world.headers
    )
    assert again.status_code == 404
    empty = world.client.get(f"{world.url}/shares", headers=world.headers).json()
    assert empty["items"] == []


def test_share_target_must_be_an_active_viewer(world: World) -> None:
    surveyor = make_user(world.db)
    inactive = make_user(world.db, role=UserRole.VIEWER, is_active=False)
    for email in (surveyor.email, inactive.email, "nobody@example.com"):
        assert share(world, email).status_code == 404, email
    assert share(world, "not-an-email").status_code == 422


def test_viewer_cannot_share_and_others_cannot_share_my_survey(world: World) -> None:
    viewer = make_user(world.db, role=UserRole.VIEWER)
    other = make_user(world.db, consented=True)
    assert share(world, viewer.email, world.headers_for(other)).status_code == 404
    unshare = world.client.delete(
        f"{world.url}/shares/{viewer.id}", headers=world.headers_for(other)
    )
    assert unshare.status_code == 404
    listing = world.client.get(f"{world.url}/shares", headers=world.headers_for(other))
    assert listing.status_code == 404


def test_share_cascades_when_viewer_is_deleted(world: World) -> None:
    viewer = make_user(world.db, role=UserRole.VIEWER)
    share(world, viewer.email)
    assert (
        world.client.delete(
            "/api/auth/me", headers=world.headers_for(viewer)
        ).status_code
        == 204
    )
    listing = world.client.get(f"{world.url}/shares", headers=world.headers).json()
    assert listing["total"] == 0


# --- openapi ----------------------------------------------------------------


def test_survey_routes_are_documented(client: TestClient) -> None:
    paths = client.get("/api/openapi.json").json()["paths"]
    for path in (
        "/api/surveys",
        "/api/surveys/{survey_id}",
        "/api/surveys/{survey_id}/readings",
        "/api/surveys/{survey_id}/checkpoints",
        "/api/surveys/{survey_id}/shares",
        "/api/surveys/{survey_id}/shares/{user_id}",
    ):
        assert path in paths
