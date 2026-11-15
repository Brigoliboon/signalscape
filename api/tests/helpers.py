import uuid

from fastapi.testclient import TestClient
from sqlalchemy import delete
from sqlalchemy.orm import Session

from app.core.security import hash_password
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
) -> User:
    user = User(
        email=email or f"{uuid.uuid4().hex[:12]}@example.com",
        name=name,
        password_hash=hash_password(password),
        role=role,
        is_active=is_active,
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
