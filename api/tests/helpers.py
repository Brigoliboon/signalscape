import uuid
from datetime import UTC, datetime

from fastapi.testclient import TestClient
from sqlalchemy import delete
from sqlalchemy.orm import Session

from app.core.security import hash_password
from app.models.building import Building, Floor
from app.models.survey import Survey, SurveyStatus
from app.models.user import User, UserRole

PASSWORD = "correct horse battery"


def make_user(
    db: Session,
    *,
    role: UserRole = UserRole.SURVEYOR,
    email: str | None = None,
    name: str = "Test User",
    password: str = PASSWORD,
    is_active: bool = True,
    consented: bool = False,
) -> User:
    user = User(
        email=email or f"{uuid.uuid4().hex[:12]}@example.com",
        name=name,
        password_hash=hash_password(password),
        role=role,
        is_active=is_active,
        consented_at=datetime.now(UTC) if consented else None,
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def login(client: TestClient, email: str, password: str = PASSWORD) -> str:
    response = client.post(
        "/api/auth/login", data={"username": email, "password": password}
    )
    assert response.status_code == 200, response.text
    return response.json()["access_token"]


def auth_headers(client: TestClient, user: User) -> dict[str, str]:
    return {"Authorization": f"Bearer {login(client, user.email)}"}


def clear_admins(db: Session) -> None:
    """Remove existing admins (rolled back with the test) so counts are exact."""
    db.execute(delete(User).where(User.role == UserRole.ADMIN))
    db.commit()


PNG_BYTES = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32
JPEG_BYTES = b"\xff\xd8\xff\xe0" + b"\x00" * 32


def make_building(
    db: Session, owner: User, *, name: str | None = None, address: str | None = None
) -> Building:
    building = Building(
        owner_id=owner.id,
        name=name or f"Building {uuid.uuid4().hex[:8]}",
        address=address,
    )
    db.add(building)
    db.commit()
    db.refresh(building)
    return building


def make_floor(
    db: Session, building: Building, *, level: int = 0, label: str | None = None
) -> Floor:
    floor = Floor(building_id=building.id, level=level, label=label or f"L{level}")
    db.add(floor)
    db.commit()
    db.refresh(floor)
    return floor


def make_survey(
    db: Session,
    building: Building,
    surveyor: User,
    *,
    status: SurveyStatus = SurveyStatus.ACTIVE,
    started_at: datetime | None = None,
) -> Survey:
    survey = Survey(
        building_id=building.id,
        surveyor_id=surveyor.id,
        status=status,
        origin_lat=14.5995,
        origin_lng=120.9842,
        origin_accuracy_m=5.0,
    )
    if started_at is not None:
        survey.started_at = started_at
    db.add(survey)
    db.commit()
    db.refresh(survey)
    return survey
