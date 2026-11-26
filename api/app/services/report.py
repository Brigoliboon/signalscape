"""AI analysis report (FR-36).

The figures come from stored processing results (or a consolidation), never
from the model. One configured OpenAI-compatible chat provider writes the
summary and recommendations; its key lives in the environment / GitHub
Actions secrets. If it is missing or fails, :class:`ReportUnavailable` is
raised and the facts remain exportable on their own.
"""

import json
import urllib.error
import urllib.request
from collections import Counter
from datetime import UTC, datetime

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import Settings, get_settings
from app.models.result import AccessPointEstimate
from app.models.survey import Survey
from app.schemas.report import AnalysisReport, ReportFacts, ReportUnavailable
from app.schemas.result import Thresholds
from app.schemas.site import ConsolidationRead
from app.services.results import access_point_location, stored_good_dbm, stored_summary

SYSTEM_PROMPT = (
    "You write concise Wi-Fi coverage reports for facility staff. Use only the "
    "figures you are given. Answer in Markdown with exactly two sections: "
    "'## Summary' and '## Recommendations'. Do not invent numbers or access "
    "points. Recommendations must be specific and practical."
)


def _weighted(floors, attribute: str) -> float:
    area = sum(floor.area_covered_m2 for floor in floors)
    if area <= 0:
        return 0.0
    return (
        sum(getattr(floor, attribute) * floor.area_covered_m2 for floor in floors)
        / area
    )


def facts_for_survey(db: Session, survey: Survey, title: str) -> ReportFacts:
    floors = stored_summary(db, survey)
    rows = db.scalars(
        select(AccessPointEstimate).where(AccessPointEstimate.survey_id == survey.id)
    ).all()
    good_dbm = stored_good_dbm(db, survey)
    determined = 0
    low_confidence = 0
    for ap in rows:
        placed, _, _ = access_point_location(ap.lat, ap.lng, ap.max_rssi_dbm, good_dbm)
        determined += int(placed)
        low_confidence += int(ap.low_confidence is not False)
    return ReportFacts(
        title=title,
        scope="survey",
        scope_id=survey.id,
        survey_ids=[survey.id],
        thresholds=Thresholds(good_dbm=good_dbm, dead_dbm=floors[0].thresholds.dead_dbm)
        if floors and floors[0].thresholds
        else Thresholds(good_dbm=good_dbm, dead_dbm=good_dbm - 13),
        floors=floors,
        reading_count=sum(floor.raw_reading_count for floor in floors),
        access_point_count=len(rows),
        determined_access_point_count=determined,
        low_confidence_count=low_confidence,
        good_pct=_weighted(floors, "good_pct"),
        fair_pct=_weighted(floors, "fair_pct"),
        dead_pct=_weighted(floors, "dead_pct"),
    )


def facts_for_consolidation(result: ConsolidationRead, title: str) -> ReportFacts:
    aps = result.access_points
    good = Counter(ap.floor_id for ap in aps if ap.position_determined)
    return ReportFacts(
        title=title,
        scope="site",
        scope_id=result.site_id,
        survey_ids=result.survey_ids,
        thresholds=result.thresholds,
        floors=result.floors,
        reading_count=sum(floor.raw_reading_count for floor in result.floors),
        access_point_count=len(aps),
        determined_access_point_count=sum(good.values()),
        low_confidence_count=sum(1 for ap in aps if ap.low_confidence is not False),
        good_pct=_weighted(result.floors, "good_pct"),
        fair_pct=_weighted(result.floors, "fair_pct"),
        dead_pct=_weighted(result.floors, "dead_pct"),
    )


def facts_text(facts: ReportFacts) -> str:
    lines = [
        f"Title: {facts.title}",
        f"Surveys: {len(facts.survey_ids)}",
        f"Thresholds: good >= {facts.thresholds.good_dbm} dBm, "
        f"dead < {facts.thresholds.dead_dbm} dBm",
        f"Readings: {facts.reading_count}",
        f"Access points: {facts.access_point_count} "
        f"({facts.determined_access_point_count} placed, "
        f"{facts.low_confidence_count} low confidence)",
        f"Area-weighted signal: {facts.good_pct:.1f}% good, "
        f"{facts.fair_pct:.1f}% fair, {facts.dead_pct:.1f}% dead",
    ]
    for floor in facts.floors:
        lines.append(
            f"- {floor.floor_label}: {floor.area_covered_m2:.0f} m2 covered, "
            f"{floor.good_pct:.1f}% good, {floor.fair_pct:.1f}% fair, "
            f"{floor.dead_pct:.1f}% dead, {floor.access_point_count} routers"
        )
    return "\n".join(lines)


def call_provider(prompt: str, settings: Settings) -> str:
    """One OpenAI-compatible chat completions call, with the key from secrets."""
    if not settings.ai_api_key:
        raise ReportUnavailable(
            "AI report is not configured: set AI_API_KEY in the server secrets"
        )
    url = f"{settings.ai_base_url.rstrip('/')}/chat/completions"
    body = json.dumps(
        {
            "model": settings.ai_model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0.3,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {settings.ai_api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=settings.ai_timeout_s) as response:
            payload = json.load(response)
        text = payload["choices"][0]["message"]["content"]
    except (
        urllib.error.URLError,
        TimeoutError,
        KeyError,
        IndexError,
        ValueError,
    ) as exc:
        raise ReportUnavailable(
            f"The AI provider could not generate a report: {exc}"
        ) from exc
    if not isinstance(text, str) or not text.strip():
        raise ReportUnavailable("The AI provider returned an empty report")
    return text.strip()


def generate(facts: ReportFacts, settings: Settings | None = None) -> AnalysisReport:
    settings = settings or get_settings()
    narrative = call_provider(facts_text(facts), settings)
    figures = "\n".join(
        f"| {floor.floor_label} | {floor.good_pct:.1f}% | {floor.fair_pct:.1f}% "
        f"| {floor.dead_pct:.1f}% | {floor.access_point_count} |"
        for floor in facts.floors
    )
    markdown = (
        f"# {facts.title}\n\n{narrative}\n\n## Coverage figures\n\n"
        "| Floor | Good | Fair | Dead | Routers |\n"
        "| --- | ---: | ---: | ---: | ---: |\n" + figures + "\n"
    )
    return AnalysisReport(
        scope=facts.scope,
        scope_id=facts.scope_id,
        generated_at=datetime.now(UTC),
        facts=facts,
        markdown=markdown,
        provider="openai-compatible",
        model=settings.ai_model,
    )


def unavailable(exc: ReportUnavailable) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)
    )
