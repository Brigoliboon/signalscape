import mimetypes
from pathlib import Path

from starlette.responses import Response
from starlette.staticfiles import StaticFiles
from starlette.types import Scope

DASHBOARD_DIR = Path(__file__).resolve().parent.parent / "static" / "dashboard"
DASHBOARD_PATH = "/api/dashboard"

mimetypes.add_type("text/javascript", ".mjs")

# The dashboard embeds the existing 3D viewer, so it may frame itself; the
# viewer keeps its own token in a URL fragment and holds no data.
SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self'; style-src 'self'; "
        "img-src 'self' data:; connect-src 'self'; frame-src 'self'; "
        "base-uri 'none'; form-action 'none'"
    ),
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
}


class DashboardFiles(StaticFiles):
    """Static files that always carry the dashboard's security headers."""

    async def get_response(self, path: str, scope: Scope) -> Response:
        response = await super().get_response(path, scope)
        response.headers.update(SECURITY_HEADERS)
        return response


def dashboard_app() -> DashboardFiles:
    return DashboardFiles(directory=DASHBOARD_DIR, html=True)
