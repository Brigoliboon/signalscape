import uuid
from datetime import datetime

from pydantic import BaseModel

from app.schemas.result import FloorSummary, Thresholds


class ReportFacts(BaseModel):
    """The figures the report is written from. They are served even when no AI
    provider is configured, so the plotted layers and FR-19 figures stay exportable."""

    title: str
    scope: str
    scope_id: uuid.UUID
    survey_ids: list[uuid.UUID]
    thresholds: Thresholds
    floors: list[FloorSummary]
    reading_count: int
    access_point_count: int
    determined_access_point_count: int
    low_confidence_count: int
    good_pct: float
    fair_pct: float
    dead_pct: float


class AnalysisReport(BaseModel):
    scope: str
    scope_id: uuid.UUID
    generated_at: datetime
    facts: ReportFacts
    markdown: str
    provider: str
    model: str


class ReportUnavailable(Exception):
    """The provider is missing or failed; the facts are still available."""
