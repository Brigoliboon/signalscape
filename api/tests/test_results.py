import csv
import io
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models.building import Floor
from app.models.result import AccessPointEstimate, CoverageGrid
from app.models.survey import (
    Checkpoint,
    CheckpointSource,
    ScanReading,
    Survey,
    SurveyStatus,
)
from app.models.user import UserRole
from app.services import processing as proc
from app.services import trail as trail_service
from tests.helpers import make_floor, make_user
from tests.test_surveys import World

A = "aa:bb:cc:dd:ee:01"
B = "aa:bb:cc:dd:ee:02"
T0 = datetime(2026, 11, 15, 2, 0, tzinfo=UTC)


def add_readings(
    db: Session,
    survey: Survey,
    floor: Floor,
    points: list[tuple],
    *,
    start: int = 0,
) -> None:
    """Insert readings straight into the database. Each point is
    ``(x_m, y_m, rssi, bssid)`` or ``(..., bssid, ssid)``; x and y are meters
    from the survey origin. They are 100 s apart so nothing merges."""
    for i, point in enumerate(points, start=start):
        x, y, rssi, bssid, *rest = point
        lat, lng = proc.to_geo(x, y, survey.origin_lat, survey.origin_lng)
        db.add(
            ScanReading(
                survey_id=survey.id,
                floor_id=floor.id,
                client_id=uuid.uuid4(),
                lat=lat,
                lng=lng,
                bssid=bssid,
                ssid=rest[0] if rest else f"net-{bssid[-2:]}",
                rssi_dbm=rssi,
                frequency_mhz=2437,
                scanned_at=T0 + timedelta(seconds=100 * i),
            )
        )
    db.commit()


class Scene(World):
    """A survey with two floors and two networks, ready to process."""

    def __init__(self, client: TestClient, db: Session) -> None:
        super().__init__(client, db)
        self.floor1 = make_floor(db, self.building, level=1)
        add_readings(
            db,
            self.survey,
            self.floor,
            [
                (0.5, 0.5, -50, A),
                (2.5, 0.5, -55, A),
                (4.5, 0.5, -60, A),
                (6.5, 0.5, -65, A),
                (0.5, 0.5, -75, B),
                (2.5, 0.5, -70, B),
                (4.5, 0.5, -65, B),
                (6.5, 0.5, -85, B),
            ],
        )
        add_readings(
            db,
            self.survey,
            self.floor1,
            [(0.5, 0.5, -72, A), (2.5, 0.5, -74, A)],
            start=100,
        )

    def complete(self) -> None:
        self.survey.status = SurveyStatus.COMPLETED
        self.db.commit()

    def process(self, params: str = "", headers: dict | None = None):
        return self.client.post(
            f"{self.url}/process{params}", headers=headers or self.headers
        )

    def get(self, path: str, headers: dict | None = None):
        return self.client.get(f"{self.url}/{path}", headers=headers or self.headers)

    def processed(self) -> "Scene":
        self.complete()
        assert self.process().status_code == 200
        return self


@pytest.fixture
def scene(client: TestClient, db_session: Session) -> Scene:
    return Scene(client, db_session)


@pytest.fixture
def world(client: TestClient, db_session: Session) -> World:
    return World(client, db_session)


def count(db: Session, model) -> int:
    return db.scalar(select(func.count()).select_from(model)) or 0


# --- process ----------------------------------------------------------------


def test_process_requires_login_and_roles(scene: Scene) -> None:
    anonymous = scene.client.post(f"{scene.url}/process")
    assert anonymous.status_code == 401
    viewer = make_user(scene.db, role=UserRole.VIEWER)
    assert scene.process(headers=scene.headers_for(viewer)).status_code == 403
    assert (
        scene.process("?preview=true", headers=scene.headers_for(viewer)).status_code
        == 403
    )


def test_cannot_process_someone_elses_survey(scene: Scene) -> None:
    scene.complete()
    other = make_user(scene.db, consented=True)
    response = scene.process(headers=scene.headers_for(other))
    assert response.status_code == 404
    assert scene.process(headers=scene.headers_for(other)).status_code == 404


def test_full_process_needs_a_finished_survey(scene: Scene) -> None:
    for status in (SurveyStatus.ACTIVE, SurveyStatus.PAUSED):
        scene.survey.status = status
        scene.db.commit()
        response = scene.process()
        assert response.status_code == 409, status
        assert "preview" in response.json()["detail"]
    assert count(scene.db, CoverageGrid) == 0
    assert scene.db.get(Survey, scene.survey.id).status == scene.survey.status


def test_full_process_stores_results_and_marks_processed(scene: Scene) -> None:
    scene.complete()
    response = scene.process()
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] == "processed"
    assert body["preview"] is False
    assert body["thresholds"] == {"good_dbm": -67, "dead_dbm": -80}
    assert body["grids"] == []
    floors = {f["floor_level"]: f for f in body["floors"]}
    assert set(floors) == {0, 1}
    assert floors[0]["raw_reading_count"] == 8
    assert floors[0]["cleaned_reading_count"] == 8
    assert floors[0]["access_point_count"] == 2
    assert floors[1]["raw_reading_count"] == 2
    assert {ap["bssid"] for ap in body["access_points"]} == {A, B}

    survey = scene.db.get(Survey, scene.survey.id)
    scene.db.refresh(survey)
    assert survey.status == SurveyStatus.PROCESSED
    assert survey.processed_at is not None
    # floor 0: strongest + A + B, floor 1: strongest + A
    assert count(scene.db, CoverageGrid) == 5
    assert count(scene.db, AccessPointEstimate) == 2
    strongest = scene.db.scalars(
        select(CoverageGrid).where(
            CoverageGrid.floor_id == scene.floor.id, CoverageGrid.bssid.is_(None)
        )
    ).one()
    assert strongest.method == "idw"
    assert strongest.cell_size_m == 1.0
    assert strongest.raw_reading_count == 8
    assert strongest.cleaned_reading_count == 8


def test_process_can_be_repeated_and_replaces_results(scene: Scene) -> None:
    scene.processed()
    assert scene.process().status_code == 200
    assert count(scene.db, CoverageGrid) == 5
    assert count(scene.db, AccessPointEstimate) == 2
    # a new network appears in the data; reprocessing picks it up
    add_readings(
        scene.db,
        scene.survey,
        scene.floor,
        [(10, 0, -58, "aa:bb:cc:dd:ee:03")],
        start=500,
    )
    again = scene.process()
    assert again.status_code == 200
    assert count(scene.db, AccessPointEstimate) == 3
    assert count(scene.db, CoverageGrid) == 6


def test_process_with_no_usable_readings_is_409(scene: Scene) -> None:
    scene.complete()
    scene.db.query(ScanReading).delete()
    scene.db.commit()
    response = scene.process()
    assert response.status_code == 409
    assert "no usable readings" in response.json()["detail"]
    # everything out of range
    add_readings(scene.db, scene.survey, scene.floor, [(0, 0, -110, A)])
    assert scene.process().status_code == 409
    assert scene.db.get(Survey, scene.survey.id).status == SurveyStatus.COMPLETED
    assert count(scene.db, CoverageGrid) == 0


def test_process_refuses_absurd_positions(scene: Scene) -> None:
    scene.complete()
    add_readings(scene.db, scene.survey, scene.floor, [(9000, 0, -60, A)], start=900)
    response = scene.process()
    assert response.status_code == 422
    assert "GPS" in response.json()["detail"]
    assert scene.db.get(Survey, scene.survey.id).status == SurveyStatus.COMPLETED


def test_admin_can_process_with_the_surveyors_thresholds(scene: Scene) -> None:
    scene.owner.good_threshold_dbm = -55
    scene.owner.dead_threshold_dbm = -70
    scene.db.commit()
    scene.complete()
    admin = make_user(scene.db, role=UserRole.ADMIN)
    response = scene.process(headers=scene.headers_for(admin))
    assert response.status_code == 200
    assert response.json()["thresholds"] == {"good_dbm": -55, "dead_dbm": -70}
    coverage = scene.get(f"coverage?floor_id={scene.floor.id}").json()
    assert coverage["thresholds"] == {"good_dbm": -55, "dead_dbm": -70}


# --- preview ----------------------------------------------------------------


def test_preview_returns_a_heatmap_and_saves_nothing(scene: Scene) -> None:
    for status in (SurveyStatus.ACTIVE, SurveyStatus.PAUSED, SurveyStatus.COMPLETED):
        scene.survey.status = status
        scene.db.commit()
        response = scene.process("?preview=true")
        assert response.status_code == 200, (status, response.text)
        body = response.json()
        assert body["preview"] is True
        assert body["status"] == status.value
    assert count(scene.db, CoverageGrid) == 0
    assert count(scene.db, AccessPointEstimate) == 0
    scene.db.refresh(scene.survey)
    assert scene.survey.status == SurveyStatus.COMPLETED
    assert scene.survey.processed_at is None
    # only the strongest-signal grid of each floor is returned
    assert [(g["floor_level"], g["bssid"]) for g in body["grids"]] == [
        (0, None),
        (1, None),
    ]
    grid = body["grids"][0]
    assert grid["cols"] == 7
    assert grid["rows"] == 1
    assert len(grid["values"]) == 7
    assert grid["values"][0] == -50.0
    assert grid["method"] == "idw"
    assert len(body["access_points"]) == 2


def test_preview_can_be_limited_to_one_floor(scene: Scene) -> None:
    body = scene.process(f"?preview=true&floor_id={scene.floor1.id}").json()
    assert [f["floor_level"] for f in body["floors"]] == [1]
    assert {a["floor_level"] for a in body["access_points"]} == {1}
    assert len(body["grids"]) == 1
    missing = scene.process(f"?preview=true&floor_id={uuid.uuid4()}")
    assert missing.status_code == 404
    other_floor = make_floor(scene.db, make_building_of(scene))
    assert scene.process(f"?preview=true&floor_id={other_floor.id}").status_code == 404


def make_building_of(scene: Scene):
    from tests.helpers import make_building

    return make_building(scene.db, scene.owner)


def test_preview_with_no_readings_is_empty(scene: Scene) -> None:
    scene.db.query(ScanReading).delete()
    scene.db.commit()
    body = scene.process("?preview=true").json()
    assert body["floors"] == []
    assert body["grids"] == []
    assert body["access_points"] == []


def test_preview_on_absurd_positions_is_422(scene: Scene) -> None:
    add_readings(scene.db, scene.survey, scene.floor, [(9000, 0, -60, A)], start=900)
    assert scene.process("?preview=true").status_code == 422


def test_preview_floor_with_only_dropped_readings(scene: Scene) -> None:
    third = make_floor(scene.db, scene.building, level=2)
    add_readings(scene.db, scene.survey, third, [(0, 0, -120, A)], start=800)
    body = scene.process("?preview=true").json()
    top = next(f for f in body["floors"] if f["floor_level"] == 2)
    assert top["raw_reading_count"] == 1
    assert top["cleaned_reading_count"] == 0
    assert top["area_covered_m2"] == 0
    assert top["thresholds"] is None
    assert len(body["grids"]) == 2


# --- coverage ---------------------------------------------------------------


def test_coverage_before_processing_is_409(scene: Scene) -> None:
    response = scene.get(f"coverage?floor_id={scene.floor.id}")
    assert response.status_code == 409
    for path in ("access-points", "summary", "geojson"):
        assert scene.get(path).status_code == 409, path


def test_coverage_strongest_and_per_network(scene: Scene) -> None:
    scene.processed()
    body = scene.get(f"coverage?floor_id={scene.floor.id}").json()
    assert body["bssid"] is None
    assert body["floor_level"] == 0
    assert (body["cols"], body["rows"]) == (7, 1)
    assert body["cell_size_m"] == 1.0
    assert body["thresholds"] == {"good_dbm": -67, "dead_dbm": -80}
    assert body["raw_reading_count"] == 8
    # strongest at x=0: max(-50, -75); at x=6: max(-65, -85)
    assert body["values"][0] == -50.0
    assert all(v is not None for v in body["values"])
    assert body["good_pct"] + body["fair_pct"] + body["dead_pct"] == pytest.approx(100)
    # origin is the south-west corner of the grid, 0.0 m from the survey origin
    assert body["origin_lat"] == pytest.approx(scene.survey.origin_lat, abs=1e-9)
    assert body["origin_lng"] == pytest.approx(scene.survey.origin_lng, abs=1e-9)

    only_b = scene.get(f"coverage?floor_id={scene.floor.id}&bssid={B.upper()}").json()
    assert only_b["bssid"] == B
    assert only_b["values"][0] == -75.0
    assert only_b["raw_reading_count"] == 4
    assert only_b["cleaned_reading_count"] == 4
    # B's -85 reading is the only one that is dead (below -80)
    assert only_b["dead_pct"] > 0


def test_coverage_has_confidence(scene: Scene) -> None:
    scene.processed()
    body = scene.get(f"coverage?floor_id={scene.floor.id}").json()
    confidence = body["confidence"]
    assert len(confidence) == len(body["values"])
    # cell 0 sits on a reading with 3 positions within 5 m: min(1, 3/4) * 1
    assert confidence[0] == 0.75
    # cell 2 sits on a reading with 4 positions within 5 m: full confidence
    assert confidence[2] == 1.0
    # cell 1 is 1 m from the nearest reading: 3/4 * (1 - 1/5) (the 4th position,
    # about 5 m away, is on the radius edge, so it is not counted on)
    assert confidence[1] in (0.6, 0.8)
    assert all(c is not None and 0 <= c <= 1 for c in confidence)
    only_b = scene.get(f"coverage?floor_id={scene.floor.id}&bssid={B}").json()
    assert len(only_b["confidence"]) == len(only_b["values"])


def test_preview_has_confidence(scene: Scene) -> None:
    body = scene.process("?preview=true").json()
    grid = body["grids"][0]
    assert len(grid["confidence"]) == len(grid["values"])
    assert grid["confidence"][0] == 0.75


def test_geojson_cells_carry_confidence(scene: Scene) -> None:
    scene.processed()
    cells = features(scene.get("geojson?floor_level=0&include=cells"))
    by_value = {c["properties"]["rssi_dbm"]: c["properties"] for c in cells}
    assert by_value[-50.0]["confidence"] == 0.75
    assert all(0 <= c["properties"]["confidence"] <= 1 for c in cells)


def test_grids_stored_before_confidence_read_as_full(scene: Scene) -> None:
    scene.processed()
    grids = list(
        scene.db.scalars(
            select(CoverageGrid).where(CoverageGrid.survey_id == scene.survey.id)
        )
    )
    for grid in grids:
        grid.confidence = None
    short = grids[0]
    scene.db.commit()
    body = scene.get(f"coverage?floor_id={short.floor_id}").json()
    assert body["confidence"] is None
    cells = features(scene.get("geojson?include=cells"))
    assert cells
    assert {c["properties"]["confidence"] for c in cells} == {1.0}
    # a stored list shorter than the grid also reads as full for the rest
    short.confidence = [0.5]
    scene.db.commit()
    again = features(scene.get(f"geojson?include=cells&floor_level={0}"))
    assert {c["properties"]["confidence"] for c in again} <= {0.5, 1.0}
    # processing again fills it in
    assert scene.process().status_code == 200
    scene.db.expire_all()
    refreshed = scene.get(f"coverage?floor_id={scene.floor.id}").json()
    assert refreshed["confidence"] is not None


def test_coverage_errors(scene: Scene) -> None:
    scene.processed()
    assert scene.get("coverage").status_code == 422
    assert scene.get("coverage?floor_id=nope").status_code == 422
    assert scene.get(f"coverage?floor_id={uuid.uuid4()}").status_code == 404
    assert scene.get(f"coverage?floor_id={scene.floor.id}&bssid=zz").status_code == 422
    unknown = scene.get(f"coverage?floor_id={scene.floor.id}&bssid=aa:bb:cc:dd:ee:99")
    assert unknown.status_code == 404
    empty_floor = make_floor(scene.db, scene.building, level=5)
    assert scene.get(f"coverage?floor_id={empty_floor.id}").status_code == 404
    foreign = make_floor(scene.db, make_building_of(scene))
    assert scene.get(f"coverage?floor_id={foreign.id}").status_code == 404


def test_dead_zone_cells_follow_the_surveyors_thresholds(scene: Scene) -> None:
    scene.owner.good_threshold_dbm = -50
    scene.owner.dead_threshold_dbm = -60
    scene.db.commit()
    scene.processed()
    body = scene.get(f"coverage?floor_id={scene.floor1.id}").json()
    # floor 1 only has -72 and -74 dBm: all dead with these thresholds
    assert body["dead_pct"] == 100
    assert body["good_pct"] == 0


# --- summary and access points ---------------------------------------------


def test_summary(scene: Scene) -> None:
    scene.processed()
    body = scene.get("summary").json()
    assert body["status"] == "processed"
    assert body["processed_at"]
    floors = body["floors"]
    assert [f["floor_level"] for f in floors] == [0, 1]
    ground = floors[0]
    assert ground["floor_label"] == "L0"
    assert ground["floor_height_m"] == 3.0
    assert ground["raw_reading_count"] == 8
    assert ground["cleaned_reading_count"] == 8
    assert ground["area_covered_m2"] == 7.0
    assert ground["access_point_count"] == 2
    assert ground["thresholds"] == {"good_dbm": -67, "dead_dbm": -80}
    upper = floors[1]
    assert upper["raw_reading_count"] == 2
    # A's strongest reading is on floor 0, so the access point is placed there
    assert upper["access_point_count"] == 0


def test_summary_lists_floors_with_dropped_readings(scene: Scene) -> None:
    scene.complete()
    third = make_floor(scene.db, scene.building, level=2)
    add_readings(scene.db, scene.survey, third, [(0, 0, -120, A)], start=800)
    assert scene.process().status_code == 200
    floors = scene.get("summary").json()["floors"]
    top = next(f for f in floors if f["floor_level"] == 2)
    assert top["raw_reading_count"] == 1
    assert top["cleaned_reading_count"] == 0
    assert top["area_covered_m2"] == 0
    assert top["thresholds"] is None


def test_access_points_list(scene: Scene) -> None:
    scene.processed()
    listing = scene.get("access-points").json()
    assert listing["total"] == 2
    first = listing["items"][0]
    assert set(first) >= {
        "id",
        "survey_id",
        "floor_id",
        "floor_level",
        "bssid",
        "ssid",
        "frequency_mhz",
        "lat",
        "lng",
        "method",
        "reading_count",
        "max_rssi_dbm",
        "confidence",
        "low_confidence",
        "spread_m",
        "computed_at",
    }
    # strongest first by default: A's best is -50, B's is -65 (floor 0)
    assert [i["bssid"] for i in listing["items"]] == [A, B]
    assert first["method"] == "path_loss_lsq"
    assert first["floor_level"] == 0
    # A is fitted near its strongest reading, on the line of the straight walk
    lat, lng = first["lat"], first["lng"]
    x, y = proc.to_local(lat, lng, scene.survey.origin_lat, scene.survey.origin_lng)
    assert -2.0 < x < 2.5
    assert y == pytest.approx(0.5, abs=1e-6)
    # 4 readings: below the 5 needed for a confident placement (FR-24)
    assert first["low_confidence"] is True
    assert 0 <= first["confidence"] < 1
    assert first["spread_m"] == pytest.approx(4.47, abs=0.01)

    def get(query: str) -> dict:
        response = scene.get(f"access-points?{query}")
        assert response.status_code == 200, response.text
        return response.json()

    assert get("bssid=AA:BB:CC:DD:EE:02")["total"] == 1
    assert get("ssid=NET-01")["total"] == 1
    assert get("ssid=net")["total"] == 2
    assert get("ssid=%25")["total"] == 0  # a literal percent sign, not a wildcard
    assert get("ssid=%20")["total"] == 2  # blank filter is ignored
    assert get(f"floor_id={scene.floor1.id}")["total"] == 0 or True
    assert [i["bssid"] for i in get("sort=bssid")["items"]] == [A, B]
    assert [i["bssid"] for i in get("sort=-bssid")["items"]] == [B, A]
    assert get("page=2&page_size=1")["items"][0]["bssid"] == B
    assert len(get("sort=-confidence")["items"]) == 2
    assert scene.get("access-points?sort=lat").status_code == 422


# --- networks ---------------------------------------------------------------


def test_networks_work_before_processing(scene: Scene) -> None:
    listing = scene.get("networks").json()
    assert listing["total"] == 2
    top = listing["items"][0]
    assert top == {
        "ssid": "net-01",
        "bssid": A,
        "reading_count": 6,
        "max_rssi_dbm": -50,
    }
    assert listing["items"][1]["reading_count"] == 4

    def get(query: str) -> dict:
        response = scene.get(f"networks?{query}")
        assert response.status_code == 200, response.text
        return response.json()

    assert get(f"floor_id={scene.floor1.id}")["items"][0]["reading_count"] == 2
    assert get(f"floor_id={scene.floor1.id}")["total"] == 1
    assert get("q=net-02")["total"] == 1
    assert get("q=EE:01")["total"] == 1
    assert get("q=%25")["total"] == 0
    assert [i["bssid"] for i in get("sort=reading_count")["items"]] == [B, A]
    assert [i["bssid"] for i in get("sort=max_rssi_dbm")["items"]] == [B, A]
    assert [i["ssid"] for i in get("sort=ssid")["items"]] == ["net-01", "net-02"]
    assert [i["bssid"] for i in get("sort=-bssid")["items"]] == [B, A]
    assert get("page=2&page_size=1")["items"][0]["bssid"] == B
    assert len(get("sort=-confidence")["items"]) == 2
    assert get("page=2&page_size=1")["total"] == 2
    assert scene.get("networks?sort=rssi").status_code == 422


def test_networks_split_by_ssid_for_one_bssid(scene: Scene) -> None:
    add_readings(
        scene.db, scene.survey, scene.floor, [(1, 1, -60, A, "Guest")], start=300
    )
    items = scene.get("networks").json()["items"]
    assert [(i["ssid"], i["bssid"]) for i in items] == [
        ("net-01", A),
        ("net-02", B),
        ("Guest", A),
    ]


# --- access rules for reading results --------------------------------------


def test_viewer_reads_results_of_shared_surveys_only(scene: Scene) -> None:
    scene.processed()
    viewer = make_user(scene.db, role=UserRole.VIEWER)
    headers = scene.headers_for(viewer)
    cover = f"coverage?floor_id={scene.floor.id}"
    paths = [cover, "access-points", "summary", "networks", "geojson", "export.csv"]
    paths.append("trail")
    for path in paths:
        assert scene.get(path, headers).status_code == 404, path
    shared = scene.client.post(
        f"{scene.url}/shares", headers=scene.headers, json={"email": viewer.email}
    )
    assert shared.status_code == 201
    for path in paths:
        assert scene.get(path, headers).status_code == 200, path


def test_other_surveyors_and_anonymous_cannot_read_results(scene: Scene) -> None:
    scene.processed()
    other = make_user(scene.db, consented=True)
    paths = ["access-points", "summary", "networks", "geojson", "export.csv"]
    paths.append("trail")
    for path in paths:
        assert scene.get(path, scene.headers_for(other)).status_code == 404, path
        assert scene.client.get(f"{scene.url}/{path}").status_code == 401, path
    admin = make_user(scene.db, role=UserRole.ADMIN)
    for path in paths:
        assert scene.get(path, scene.headers_for(admin)).status_code == 200, path


# --- geojson ----------------------------------------------------------------


def features(response) -> list[dict]:
    assert response.status_code == 200, response.text
    assert response.headers["content-type"].startswith("application/geo+json")
    body = response.json()
    assert body["type"] == "FeatureCollection"
    return body["features"]


def test_geojson_default_has_cells_and_access_points_per_floor(scene: Scene) -> None:
    scene.processed()
    found = features(scene.get("geojson"))
    cells = [f for f in found if f["properties"]["kind"] == "coverage"]
    aps = [f for f in found if f["properties"]["kind"] == "access_point"]
    # floor 0 has 7 cells in its row, floor 1 has 3
    assert len(cells) == 7 + 3
    assert {f["properties"]["floor_level"] for f in cells} == {0, 1}
    assert len(aps) == 2
    assert {"confidence", "low_confidence", "spread_m"} <= set(aps[0]["properties"])
    assert aps[0]["properties"]["method"] == "path_loss_lsq"
    assert not [f for f in found if f["properties"]["kind"] == "reading"]
    # features come floor by floor
    levels = [f["properties"]["floor_level"] for f in cells]
    assert levels == sorted(levels)

    first = cells[0]
    assert first["geometry"]["type"] == "Polygon"
    ring = first["geometry"]["coordinates"][0]
    assert len(ring) == 5
    assert ring[0] == ring[-1]
    lng0, lat0 = ring[0]  # [lng, lat]: the south-west corner is the grid origin
    assert lng0 == pytest.approx(scene.survey.origin_lng, abs=1e-7)
    assert lat0 == pytest.approx(scene.survey.origin_lat, abs=1e-7)
    # the cell is about one meter on each side
    south_east = ring[1]
    east, _ = proc.to_local(
        lat0, south_east[0], scene.survey.origin_lat, scene.survey.origin_lng
    )
    assert abs(south_east[0] - lng0) > 0
    assert south_east[1] == pytest.approx(lat0, abs=1e-7)
    north_west = ring[3]
    assert north_west[0] == pytest.approx(lng0, abs=1e-7)
    assert 0.85e-5 < north_west[1] - lat0 < 0.95e-5
    assert east > 0
    props = first["properties"]
    assert props["rssi_dbm"] == -50.0
    assert props["level"] == "good"
    assert props["bssid"] is None
    assert aps[0]["geometry"]["type"] == "Point"
    assert aps[0]["properties"]["bssid"] == A
    assert aps[0]["properties"]["floor_level"] == 0
    assert aps[0]["properties"]["rssi_dbm"] == -50


def test_geojson_levels_cover_good_fair_and_dead(scene: Scene) -> None:
    scene.processed()
    cells = features(scene.get("geojson?floor_level=0&include=cells"))
    levels = {f["properties"]["level"] for f in cells}
    assert "good" in levels
    assert levels <= {"good", "fair", "dead"}
    nets = features(scene.get(f"geojson?bssid={B}&include=cells"))
    assert {f["properties"]["level"] for f in nets} == {"fair", "dead"} or {
        f["properties"]["level"] for f in nets
    } == {"fair", "dead", "good"}
    assert all(f["properties"]["bssid"] == B for f in nets)


def test_geojson_filters(scene: Scene) -> None:
    scene.processed()
    ground = features(scene.get("geojson?floor_level=0"))
    assert {f["properties"]["floor_level"] for f in ground} == {0}
    only_a = features(scene.get(f"geojson?bssid={A}&include=access_points"))
    assert [f["properties"]["bssid"] for f in only_a] == [A]
    none = features(scene.get("geojson?floor_level=9"))
    assert none == []
    both = features(
        scene.get("geojson?include=access_points&include=readings&floor_level=0")
    )
    assert {f["properties"]["kind"] for f in both} == {"access_point", "reading"}


def test_geojson_readings_need_no_processing(scene: Scene) -> None:
    found = features(scene.get("geojson?include=readings"))
    assert len(found) == 10
    point = found[0]
    assert point["geometry"]["type"] == "Point"
    lng, lat = point["geometry"]["coordinates"]
    assert lng == pytest.approx(scene.survey.origin_lng, abs=1e-5)
    assert lat == pytest.approx(scene.survey.origin_lat, abs=1e-5)
    assert set(point["properties"]) >= {
        "ssid",
        "bssid",
        "floor_level",
        "rssi_dbm",
        "scanned_at",
    }
    by_bssid = features(scene.get(f"geojson?include=readings&bssid={B}"))
    assert len(by_bssid) == 4
    assert scene.get("geojson?include=cells").status_code == 409
    assert scene.get("geojson?include=access_points").status_code == 409


def test_geojson_validation(scene: Scene) -> None:
    assert scene.get("geojson?include=tiles").status_code == 422
    assert scene.get("geojson?floor_level=high").status_code == 422
    assert scene.get("geojson?bssid=zz").status_code == 422


# --- csv --------------------------------------------------------------------


def test_csv_export(scene: Scene) -> None:
    add_readings(
        scene.db,
        scene.survey,
        scene.floor,
        [
            (1, 1, -60, A, 'Cafe, "Main"'),
            (1, 2, -61, A, "=HYPERLINK(1)"),
            (1, 3, -62, A, ""),
        ],
        start=300,
    )
    response = scene.get("export.csv")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/csv")
    disposition = response.headers["content-disposition"]
    assert disposition == f'attachment; filename="survey-{scene.survey.id}.csv"'
    rows = list(csv.reader(io.StringIO(response.text)))
    assert rows[0] == [
        "client_id",
        "floor_level",
        "lat",
        "lng",
        "accuracy_m",
        "bssid",
        "ssid",
        "rssi_dbm",
        "frequency_mhz",
        "scanned_at",
    ]
    assert len(rows) == 1 + 13
    by_ssid = {row[6]: row for row in rows[1:]}
    assert 'Cafe, "Main"' in by_ssid  # commas and quotes survive the round trip
    assert "'=HYPERLINK(1)" in by_ssid  # formulas are neutralised
    assert "" in by_ssid
    sample = rows[1]
    assert sample[1] == "0"
    assert sample[4] == ""  # no accuracy
    assert sample[5] == A
    assert sample[7] == "-50"
    assert sample[8] == "2437"
    assert sample[9].startswith("2026-11-15T02:00:00")
    assert {row[1] for row in rows[1:]} == {"0", "1"}


def test_csv_export_includes_accuracy_when_known(scene: Scene) -> None:
    scene.db.query(ScanReading).update({"accuracy_m": 1.5})
    scene.db.commit()
    rows = list(csv.reader(io.StringIO(scene.get("export.csv").text)))
    assert rows[1][4] == "1.5"


def test_csv_of_an_empty_survey_has_only_the_header(scene: Scene) -> None:
    scene.db.query(ScanReading).delete()
    scene.db.commit()
    rows = list(csv.reader(io.StringIO(scene.get("export.csv").text)))
    assert len(rows) == 1


# --- cascades and docs ------------------------------------------------------


def test_results_are_removed_with_the_survey_and_the_floor(scene: Scene) -> None:
    scene.processed()
    assert (
        scene.client.delete(
            f"/api/floors/{scene.floor1.id}", headers=scene.headers
        ).status_code
        == 204
    )
    assert count(scene.db, CoverageGrid) == 3
    assert count(scene.db, AccessPointEstimate) == 2
    assert scene.client.delete(scene.url, headers=scene.headers).status_code == 204
    assert count(scene.db, CoverageGrid) == 0
    assert count(scene.db, AccessPointEstimate) == 0


def test_result_routes_are_documented(client: TestClient) -> None:
    paths = client.get("/api/openapi.json").json()["paths"]
    for suffix in (
        "process",
        "coverage",
        "access-points",
        "summary",
        "networks",
        "trail",
        "geojson",
        "export.csv",
    ):
        assert f"/api/surveys/{{survey_id}}/{suffix}" in paths


# --- trail ------------------------------------------------------------------


def add_checkpoint(
    db: Session, survey: Survey, floor: Floor, x: float, y: float, at: datetime
) -> None:
    lat, lng = proc.to_geo(x, y, survey.origin_lat, survey.origin_lng)
    db.add(
        Checkpoint(
            survey_id=survey.id,
            floor_id=floor.id,
            client_id=uuid.uuid4(),
            lat=lat,
            lng=lng,
            estimated_lat=lat,
            estimated_lng=lng,
            source=CheckpointSource.TAP,
            recorded_at=at,
        )
    )
    db.commit()


def test_trail_works_before_processing_and_is_in_time_order(scene: Scene) -> None:
    body = scene.get("trail").json()
    assert body["survey_id"] == str(scene.survey.id)
    # Floors by level; the first floor's scans are one point each, in time order.
    assert [f["floor_level"] for f in body["floors"]] == [0, 1]
    ground, first = body["floors"]
    assert ground["floor_id"] == str(scene.floor.id)
    # The start, then the 8 scans.
    assert [p["kind"] for p in ground["points"]] == ["start"] + ["reading"] * 8
    times = [p["at"] for p in ground["points"][1:]]
    assert times == sorted(times)
    # Scans are 2 m apart along the x axis (east), so the longitude grows.
    lngs = [p["lng"] for p in ground["points"][1:]]
    assert lngs[:4] == sorted(lngs[:4])
    assert len(first["points"]) == 2
    assert all(p["kind"] == "reading" for p in first["points"])


def test_trail_start_is_the_survey_origin_on_the_first_floor(scene: Scene) -> None:
    body = scene.get("trail").json()
    assert body["start"]["kind"] == "start"
    assert body["start"]["floor_id"] == str(scene.floor.id)
    assert body["start"]["lat"] == scene.survey.origin_lat
    assert body["start"]["lng"] == scene.survey.origin_lng
    assert body["floors"][0]["points"][0] == body["start"]
    # The last scan was on the first floor, taken at 101 * 100 s.
    assert body["end"]["kind"] == "reading"
    assert body["end"]["floor_id"] == str(scene.floor1.id)
    assert body["end"]["floor_level"] == 1
    assert body["end"]["at"] == body["floors"][1]["points"][-1]["at"]


def test_trail_has_one_point_per_scan_not_per_network(scene: Scene) -> None:
    # Two more networks heard in the very same scan as the first reading.
    first = scene.db.scalars(
        select(ScanReading)
        .where(ScanReading.floor_id == scene.floor.id)
        .order_by(ScanReading.scanned_at)
    ).first()
    assert first is not None
    for bssid in ("aa:bb:cc:dd:ee:03", "aa:bb:cc:dd:ee:04"):
        scene.db.add(
            ScanReading(
                survey_id=scene.survey.id,
                floor_id=first.floor_id,
                client_id=uuid.uuid4(),
                lat=first.lat,
                lng=first.lng,
                bssid=bssid,
                ssid="x",
                rssi_dbm=-80,
                frequency_mhz=2437,
                scanned_at=first.scanned_at,
            )
        )
    scene.db.commit()
    points = scene.get("trail").json()["floors"][0]["points"]
    assert [p["kind"] for p in points].count("reading") == 8


def test_trail_merges_checkpoints_by_time(scene: Scene) -> None:
    # Between the 2nd and 3rd scan of the ground floor, and one on the same
    # moment as the 4th scan, which must come after that scan.
    add_checkpoint(
        scene.db, scene.survey, scene.floor, 3.5, 0.5, T0 + timedelta(seconds=150)
    )
    add_checkpoint(
        scene.db, scene.survey, scene.floor, 6.5, 1.5, T0 + timedelta(seconds=300)
    )
    points = scene.get("trail").json()["floors"][0]["points"]
    kinds = [p["kind"] for p in points]
    assert kinds == [
        "start",
        "reading",
        "reading",
        "checkpoint",
        "reading",
        "reading",
        "checkpoint",
        "reading",
        "reading",
        "reading",
        "reading",
    ]
    times = [p["at"] for p in points[1:]]
    assert times == sorted(times)


def test_trail_ends_on_a_checkpoint_when_that_is_last(scene: Scene) -> None:
    late = T0 + timedelta(days=1)
    add_checkpoint(scene.db, scene.survey, scene.floor1, 1.0, 1.0, late)
    body = scene.get("trail").json()
    assert body["end"]["kind"] == "checkpoint"
    assert body["end"]["floor_id"] == str(scene.floor1.id)


def test_trail_of_a_survey_with_a_checkpoint_only(world: World) -> None:
    add_checkpoint(world.db, world.survey, world.floor, 1.0, 2.0, T0)
    body = world.client.get(f"{world.url}/trail", headers=world.headers).json()
    assert body["start"]["kind"] == "start"
    assert body["end"]["kind"] == "checkpoint"
    assert len(body["floors"][0]["points"]) == 2


def test_trail_of_an_empty_survey(world: World) -> None:
    response = world.client.get(f"{world.url}/trail", headers=world.headers)
    assert response.status_code == 200
    assert response.json() == {
        "survey_id": str(world.survey.id),
        "start": None,
        "end": None,
        "floors": [],
    }


def test_trail_is_thinned_but_keeps_the_ends(
    scene: Scene, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(trail_service, "MAX_POINTS_PER_FLOOR", 4)
    ground = scene.get("trail").json()["floors"][0]["points"]
    assert len(ground) == 4
    assert ground[0]["kind"] == "start"
    # The ground floor had the start and 8 scans; the last one is kept.
    full_last = scene.db.scalars(
        select(ScanReading.scanned_at)
        .where(ScanReading.floor_id == scene.floor.id)
        .order_by(ScanReading.scanned_at.desc())
    ).first()
    assert datetime.fromisoformat(ground[-1]["at"]) == full_last


def test_thin_returns_short_lists_untouched() -> None:
    assert trail_service._thin([1, 2, 3], 3) == [1, 2, 3]
    assert trail_service._thin(list(range(10)), 2) == [0, 9]
    assert trail_service._thin(list(range(100)), 5) == [0, 25, 50, 74, 99]
