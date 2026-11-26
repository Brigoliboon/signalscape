"""The 3D coverage page (FR-16), served as static files.

The page is the same for everyone and carries no survey data, so it needs no login.
It loads its data from the normal API with the bearer token the app hands it (see
``docs/DESIGN.md``, section 6.1), so every access rule still applies there.
"""

import mimetypes
from pathlib import Path

from starlette.responses import Response
from starlette.staticfiles import StaticFiles
from starlette.types import Scope

VIEWER_DIR = Path(__file__).resolve().parent.parent / "static" / "viewer"
VIEWER_PATH = "/api/viewer"

# Our own modules use .mjs so tools like Node treat them as ES modules.
mimetypes.add_type("text/javascript", ".mjs")

# The page loads only its own files and talks only to its own origin. Three.js and
# OrbitControls are vendored, so no third-party host is involved. It may only be
# framed by the dashboard on this same origin.
SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self'; style-src 'self'; "
        "img-src 'self' data:; connect-src 'self'; base-uri 'none'; "
        "form-action 'none'; frame-ancestors 'self'"
    ),
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
}


class ViewerFiles(StaticFiles):
    """Static files that always carry the page's security headers."""

    async def get_response(self, path: str, scope: Scope) -> Response:
        response = await super().get_response(path, scope)
        response.headers.update(SECURITY_HEADERS)
        return response


def viewer_app() -> ViewerFiles:
    return ViewerFiles(directory=VIEWER_DIR, html=True)
