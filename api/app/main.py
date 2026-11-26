from fastapi import FastAPI

from app.api.auth import router as auth_router
from app.api.buildings import router as buildings_router
from app.api.dashboard import DASHBOARD_PATH, dashboard_app
from app.api.floors import router as floors_router
from app.api.health import router as health_router
from app.api.report import router as report_router
from app.api.results import router as results_router
from app.api.sites import router as sites_router
from app.api.surveys import router as surveys_router
from app.api.users import router as users_router
from app.api.viewer import VIEWER_PATH, viewer_app
from app.core.config import get_settings

settings = get_settings()

app = FastAPI(
    title=settings.app_name,
    version="1.0.0",
    docs_url="/api/docs",
    redoc_url="/api/redoc",
    openapi_url="/api/openapi.json",
)

app.include_router(health_router)
app.include_router(auth_router)
app.include_router(users_router)
app.include_router(buildings_router)
app.include_router(floors_router)
app.include_router(surveys_router)
app.include_router(results_router)
app.include_router(sites_router)
app.include_router(report_router)
app.mount(VIEWER_PATH, viewer_app(), name="viewer")
app.mount(DASHBOARD_PATH, dashboard_app(), name="dashboard")
