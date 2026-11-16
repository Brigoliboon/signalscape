"""The 3D coverage page: served as static files with security headers."""

import re
import shutil
import subprocess
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.api.viewer import SECURITY_HEADERS, VIEWER_DIR

JS_TESTS = [
    Path(__file__).parent / "js" / "levels.test.mjs",
    Path(__file__).parent / "js" / "heat.test.mjs",
]
OUR_FILES = ["index.html", "viewer.mjs", "levels.mjs", "heat.mjs", "viewer.css"]
VENDORED = ["three.module.js", "three.core.js", "OrbitControls.js", "LICENSE"]


def test_page_is_served_without_login(client: TestClient) -> None:
    response = client.get("/api/viewer/")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    assert '<script type="module" src="viewer.mjs">' in response.text
    assert '<link rel="stylesheet" href="viewer.css">' in response.text
    assert 'name="viewport"' in response.text
    index = client.get("/api/viewer/index.html")
    assert index.status_code == 200
    assert index.text == response.text


def test_missing_slash_redirects_to_the_page(client: TestClient) -> None:
    response = client.get("/api/viewer", follow_redirects=False)
    assert response.status_code in (307, 308)
    assert response.headers["location"].endswith("/api/viewer/")


@pytest.mark.parametrize(
    "path", ["", "viewer.mjs", "levels.mjs", "heat.mjs", "viewer.css"]
)
def test_security_headers(client: TestClient, path: str) -> None:
    response = client.get(f"/api/viewer/{path}")
    assert response.status_code == 200
    for name, value in SECURITY_HEADERS.items():
        assert response.headers[name] == value
    csp = response.headers["content-security-policy"]
    assert "default-src 'none'" in csp
    assert "script-src 'self'" in csp
    assert "unsafe-inline" not in csp
    assert "unsafe-eval" not in csp
    assert "connect-src 'self'" in csp
    assert response.headers["referrer-policy"] == "no-referrer"
    assert response.headers["x-content-type-options"] == "nosniff"


def test_scripts_have_a_javascript_content_type(client: TestClient) -> None:
    for name in ("viewer.mjs", "levels.mjs", "heat.mjs", "vendor/three.module.js"):
        response = client.get(f"/api/viewer/{name}")
        assert response.status_code == 200, name
        assert response.headers["content-type"].startswith(
            ("text/javascript", "application/javascript")
        ), name
    assert (
        client.get("/api/viewer/viewer.css")
        .headers["content-type"]
        .startswith("text/css")
    )


def test_vendored_files_are_present_and_import_each_other_locally(
    client: TestClient,
) -> None:
    for name in VENDORED:
        assert client.get(f"/api/viewer/vendor/{name}").status_code == 200, name
    controls = client.get("/api/viewer/vendor/OrbitControls.js").text
    assert 'from"./three.module.js"' in controls
    assert 'from"three"' not in controls
    assert "MIT" in client.get("/api/viewer/vendor/LICENSE").text
    module = client.get("/api/viewer/vendor/three.module.js").text
    assert 'from"./three.core.js"' in module


def test_page_only_talks_to_its_own_origin() -> None:
    """No file of ours may load anything from another host."""
    for name in OUR_FILES:
        text = (VIEWER_DIR / name).read_text()
        assert not re.search(r"https?://", text), name
    for vendored in (VIEWER_DIR / "vendor").glob("*.js"):
        assert " eval(" not in vendored.read_text(), vendored.name


def test_page_does_not_use_innerhtml_or_inline_handlers() -> None:
    script = (VIEWER_DIR / "viewer.mjs").read_text()
    assert "innerHTML" not in script
    assert "insertAdjacentHTML" not in script
    html = (VIEWER_DIR / "index.html").read_text()
    assert not re.search(r"\son[a-z]+=", html)
    assert "<script>" not in html
    assert " style=" not in html


def test_unknown_files_are_404(client: TestClient) -> None:
    assert client.get("/api/viewer/nothing.js").status_code == 404
    assert client.get("/api/viewer/vendor/").status_code == 404


def test_viewer_cannot_read_files_outside_its_folder(client: TestClient) -> None:
    for path in (
        "../main.py",
        "..%2fmain.py",
        "%2e%2e/main.py",
        "vendor/../../main.py",
        "....//main.py",
    ):
        response = client.get(f"/api/viewer/{path}")
        assert response.status_code == 404, path
        assert "FastAPI(" not in response.text


def test_viewer_is_not_part_of_the_json_api_docs(client: TestClient) -> None:
    paths = client.get("/api/openapi.json").json()["paths"]
    assert not [p for p in paths if p.startswith("/api/viewer")]
    assert "/api/health" in paths


NODE = shutil.which("node")


def test_page_layout_has_one_toolbar_and_one_dock() -> None:
    """Controls live in a toolbar and a dock; every toggle points at a real panel."""
    html = (VIEWER_DIR / "index.html").read_text()
    ids = set(re.findall(r'\sid="([^"]+)"', html))
    for toggle in ("legend-toggle", "layers-toggle"):
        assert toggle in ids
    for target in re.findall(r'aria-controls="([^"]+)"', html):
        assert target in ids, target
    assert html.count('class="toolbar"') == 1
    assert html.count('id="dock"') == 1
    # The tap info and the Layers sheet share the dock, so they cannot overlap.
    dock = html[html.index('id="dock"') :]
    assert 'id="info"' in dock
    assert 'id="layers"' in dock
    # The legend is collapsible and the collapsed chip keeps a small gradient bar.
    assert 'id="legend-panel"' in html
    assert 'id="ramp-mini"' in html
    assert 'aria-expanded="false" aria-controls="legend-panel"' in html
    script = (VIEWER_DIR / "viewer.mjs").read_text()
    assert "sessionStorage" in script
    assert "legendStartsOpen" in script


@pytest.mark.skipif(NODE is None, reason="Node.js is not installed")
def test_viewer_scripts_have_valid_syntax() -> None:
    for name in ("viewer.mjs", "levels.mjs", "heat.mjs"):
        result = subprocess.run(
            [NODE, "--check", str(VIEWER_DIR / name)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert result.returncode == 0, result.stderr


@pytest.mark.skipif(NODE is None, reason="Node.js is not installed")
def test_color_threshold_and_heatmap_helpers_pass_their_node_tests() -> None:
    result = subprocess.run(
        [NODE, "--test", *map(str, JS_TESTS)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr
