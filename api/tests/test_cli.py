from contextlib import contextmanager

import pytest
from sqlalchemy.orm import Session

from app import cli
from app.core.security import verify_password
from app.models.user import UserRole
from tests.helpers import make_user


def test_create_admin(db_session: Session) -> None:
    user = cli.create_admin(
        db_session, " Root@Example.com ", " Root ", "long-enough-pw"
    )
    assert user.email == "root@example.com"
    assert user.name == "Root"
    assert user.role == UserRole.ADMIN
    assert user.is_active
    assert verify_password("long-enough-pw", user.password_hash)


def test_create_admin_validates_input(db_session: Session) -> None:
    with pytest.raises(cli.CliError):
        cli.create_admin(db_session, "no-at-sign", "Root", "long-enough-pw")
    with pytest.raises(cli.CliError):
        cli.create_admin(db_session, "a@example.com", "Root", "short")
    with pytest.raises(cli.CliError):
        cli.create_admin(db_session, "a@example.com", "Root", "é" * 40)


def test_create_admin_existing_email(db_session: Session) -> None:
    existing = make_user(db_session, email="taken@example.com", is_active=False)
    with pytest.raises(cli.CliError, match="already exists"):
        cli.create_admin(db_session, "TAKEN@example.com", "X", "long-enough-pw")
    assert existing.role == UserRole.SURVEYOR

    promoted = cli.create_admin(
        db_session, "taken@example.com", "X", "long-enough-pw", promote=True
    )
    assert promoted.id == existing.id
    assert promoted.role == UserRole.ADMIN
    assert promoted.is_active
    # Password is untouched when promoting.
    assert not verify_password("long-enough-pw", promoted.password_hash)


@pytest.fixture
def cli_session(monkeypatch: pytest.MonkeyPatch, db_session: Session):
    @contextmanager
    def fake_session_local():
        yield db_session

    monkeypatch.setattr(cli, "SessionLocal", fake_session_local)
    return db_session


def test_main_reads_password_from_env(
    cli_session: Session,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv(cli.PASSWORD_ENV, "env-password-1")
    code = cli.main(["create-admin", "--email", "cli@example.com", "--name", "Cli"])
    assert code == 0
    assert "cli@example.com" in capsys.readouterr().out
    # Second run hits the duplicate error and exits non-zero.
    code = cli.main(["create-admin", "--email", "cli@example.com", "--name", "Cli"])
    assert code == 1
    assert "already exists" in capsys.readouterr().err
    assert (
        cli.main(
            ["create-admin", "--email", "cli@example.com", "--name", "Cli", "--promote"]
        )
        == 0
    )


def test_main_prompts_for_password(
    cli_session: Session,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.delenv(cli.PASSWORD_ENV, raising=False)
    answers = iter(["prompted-pass", "prompted-pass"])
    monkeypatch.setattr(cli.getpass, "getpass", lambda _prompt: next(answers))
    code = cli.main(["create-admin", "--email", "p@example.com", "--name", "P"])
    assert code == 0

    answers = iter(["one-password", "another-password"])
    code = cli.main(["create-admin", "--email", "q@example.com", "--name", "Q"])
    assert code == 1
    assert "do not match" in capsys.readouterr().err
