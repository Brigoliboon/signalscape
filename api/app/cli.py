"""Command line tools. Run with ``python -m app.cli <command>``."""

import argparse
import getpass
import os
import sys
from collections.abc import Sequence

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.security import MAX_PASSWORD_BYTES, hash_password
from app.db.session import SessionLocal
from app.models.user import User, UserRole

PASSWORD_ENV = "SIGNALSCAPE_ADMIN_PASSWORD"
MIN_PASSWORD_LENGTH = 8


class CliError(Exception):
    pass


def create_admin(
    db: Session, email: str, name: str, password: str, promote: bool = False
) -> User:
    """Create an active admin. With ``promote``, upgrade an existing account."""
    email = email.strip().lower()
    if "@" not in email:
        raise CliError("Invalid email address")
    if len(password) < MIN_PASSWORD_LENGTH:
        raise CliError(f"Password must be at least {MIN_PASSWORD_LENGTH} characters")
    if len(password.encode("utf-8")) > MAX_PASSWORD_BYTES:
        raise CliError(f"Password must be at most {MAX_PASSWORD_BYTES} bytes")

    existing = db.scalar(select(User).where(func.lower(User.email) == email))
    if existing is not None:
        if not promote:
            raise CliError(
                f"{email} already exists. Use --promote to make it an admin "
                "(its password is left unchanged)."
            )
        existing.role = UserRole.ADMIN
        existing.is_active = True
        db.commit()
        db.refresh(existing)
        return existing

    user = User(
        email=email,
        name=name.strip(),
        password_hash=hash_password(password),
        role=UserRole.ADMIN,
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def _read_password() -> str:
    password = os.environ.get(PASSWORD_ENV)
    if password:
        return password
    password = getpass.getpass("Password: ")
    if password != getpass.getpass("Repeat password: "):
        raise CliError("Passwords do not match")
    return password


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.cli")
    sub = parser.add_subparsers(dest="command", required=True)
    admin = sub.add_parser(
        "create-admin",
        help=f"create an admin (password from ${PASSWORD_ENV} or a prompt)",
    )
    admin.add_argument("--email", required=True)
    admin.add_argument("--name", required=True)
    admin.add_argument(
        "--promote",
        action="store_true",
        help="if the email already exists, make that account an admin",
    )
    args = parser.parse_args(argv)

    try:
        password = _read_password()
        with SessionLocal() as db:
            user = create_admin(db, args.email, args.name, password, args.promote)
            print(f"Admin ready: {user.email} ({user.id})")
    except CliError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
