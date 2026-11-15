from datetime import UTC, datetime, timedelta

import jwt

from app.core.config import get_settings
from app.core.security import (
    create_access_token,
    decode_access_token,
    hash_password,
    verify_password,
)


def test_hash_and_verify_password() -> None:
    hashed = hash_password("s3cret-pass")
    assert hashed != "s3cret-pass"
    assert hashed.startswith("$2")
    assert verify_password("s3cret-pass", hashed)
    assert not verify_password("wrong", hashed)


def test_verify_password_handles_bad_input() -> None:
    assert not verify_password("x" * 100, hash_password("short-pass"))
    assert not verify_password("anything", "not-a-bcrypt-hash")


def test_token_round_trip() -> None:
    token, expires_in = create_access_token("user-1", "admin")
    assert expires_in == 24 * 60 * 60
    claims = decode_access_token(token)
    assert claims is not None
    assert claims["sub"] == "user-1"
    assert claims["role"] == "admin"
    assert claims["exp"] - claims["iat"] == expires_in


def test_decode_rejects_bad_tokens() -> None:
    settings = get_settings()
    assert decode_access_token("garbage") is None

    forged = jwt.encode({"sub": "u", "exp": 9999999999}, "other", algorithm="HS256")
    assert decode_access_token(forged) is None

    expired = jwt.encode(
        {"sub": "u", "exp": datetime.now(UTC) - timedelta(minutes=1)},
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )
    assert decode_access_token(expired) is None

    no_exp = jwt.encode({"sub": "u"}, settings.jwt_secret, algorithm="HS256")
    assert decode_access_token(no_exp) is None
