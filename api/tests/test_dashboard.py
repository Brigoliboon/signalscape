"""The browser dashboard: static files with security headers, no data on the page."""

import re
import shutil
import subprocess
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.api.dashboard import DASHBOARD_DIR, SECURITY_HEADERS

SCRIPTS = ["dashboard.mjs", "lib.mjs", "mapview.mjs"]
OUR_FILES = ["index.html", "dashboard.css", *SCRIPTS]


def test_page_is_served_without_login(client: TestClient) -> None:
    response = client.get("/api/dashboard/")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    assert '<script type="module" src="dashboard.mjs">' in response.text
    assert '<link rel="stylesheet" href="dashboard.css">' in response.text
    assert 'name="viewport"' in response.text
    for element in (
        "login-form",
        "site",
        "building",
        "survey",
        "map",
        "viewer",
        "report",
        "stage",
        "view-tabs",
        "inspector-tabs",
        "summary-body",
        "legend",
        "toasts",
    ):
        assert f'id="{element}"' in response.text


def test_page_has_the_landmarks_and_labels_a_keyboard_user_needs() -> None:
    html = (DASHBOARD_DIR / "index.html").read_text()
    assert '<html lang="en">' in html
    assert 'class="skip-link" href="#stage"' in html
    assert html.count("<h1") >= 2  # sign-in and the stage each have one
    for role in (
        'role="tablist"',
        'role="tabpanel"',
        'role="radiogroup"',
        'role="status"',
    ):
        assert role in html
    # Every form control has a visible label.
    for control in ("email", "password", "site", "building", "network", "site-name"):
        assert f'for="{control}"' in html, control


def test_missing_slash_redirects_to_the_page(client: TestClient) -> None:
    response = client.get("/api/dashboard", follow_redirects=False)
    assert response.status_code in (307, 308)
    assert response.headers["location"].endswith("/api/dashboard/")


@pytest.mark.parametrize("path", ["", "dashboard.css", *SCRIPTS])
def test_security_headers(client: TestClient, path: str) -> None:
    response = client.get(f"/api/dashboard/{path}")
    assert response.status_code == 200
    for name, value in SECURITY_HEADERS.items():
        assert response.headers[name] == value
    csp = response.headers["content-security-policy"]
    assert "default-src 'none'" in csp
    assert "script-src 'self'" in csp
    assert "frame-src 'self'" in csp
    assert "unsafe-inline" not in csp
    assert "unsafe-eval" not in csp
    assert response.headers["referrer-policy"] == "no-referrer"
    assert response.headers["x-content-type-options"] == "nosniff"


@pytest.mark.parametrize("name", SCRIPTS)
def test_modules_have_a_javascript_content_type(client: TestClient, name: str) -> None:
    script = client.get(f"/api/dashboard/{name}")
    assert script.status_code == 200
    assert script.headers["content-type"].startswith(
        ("text/javascript", "application/javascript")
    )


def test_styles_have_the_right_content_type(client: TestClient) -> None:
    assert (
        client.get("/api/dashboard/dashboard.css")
        .headers["content-type"]
        .startswith("text/css")
    )


def test_page_talks_only_to_its_own_origin() -> None:
    for name in OUR_FILES:
        text = (DASHBOARD_DIR / name).read_text()
        assert not re.search(r"https?://", text), name


def test_page_does_not_use_innerhtml_or_inline_handlers() -> None:
    for name in SCRIPTS:
        script = (DASHBOARD_DIR / name).read_text()
        assert "innerHTML" not in script, name
        assert "outerHTML" not in script, name
        assert "insertAdjacentHTML" not in script, name
        assert "document.write" not in script, name
        assert "eval(" not in script, name
    html = (DASHBOARD_DIR / "index.html").read_text()
    assert not re.search(r"\son[a-z]+=", html)
    assert "<script>" not in html
    assert " style=" not in html


def test_unknown_files_are_404(client: TestClient) -> None:
    assert client.get("/api/dashboard/nothing.js").status_code == 404


def test_dashboard_cannot_read_files_outside_its_folder(client: TestClient) -> None:
    for path in ("../main.py", "..%2fmain.py", "%2e%2e/main.py"):
        response = client.get(f"/api/dashboard/{path}")
        assert response.status_code == 404, path
        assert "FastAPI(" not in response.text


def test_dashboard_and_viewer_are_not_part_of_the_json_api_docs(
    client: TestClient,
) -> None:
    paths = client.get("/api/openapi.json").json()["paths"]
    assert not [p for p in paths if p.startswith("/api/dashboard")]
    assert not [p for p in paths if p.startswith("/api/viewer")]
    assert "/api/sites" in paths
    assert "/api/health" in paths


def test_embedded_viewer_may_only_be_framed_by_this_origin(client: TestClient) -> None:
    csp = client.get("/api/viewer/").headers["content-security-policy"]
    assert "frame-ancestors 'self'" in csp
    assert "frame-ancestors 'none'" not in csp


NODE = shutil.which("node")


@pytest.mark.skipif(NODE is None, reason="Node.js is not installed")
@pytest.mark.parametrize("name", SCRIPTS)
def test_dashboard_script_has_valid_syntax(name: str) -> None:
    result = subprocess.run(
        [NODE, "--check", str(DASHBOARD_DIR / name)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, result.stderr


@pytest.mark.skipif(NODE is None, reason="Node.js is not installed")
def test_dashboard_helpers_pass_their_node_tests() -> None:
    test_file = Path(__file__).parent / "js" / "dashboard.test.mjs"
    result = subprocess.run(
        [NODE, "--test", str(test_file)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr
