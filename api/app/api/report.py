import uuid

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.session import get_db
from app.models.building import Building
from app.models.survey import Survey
from app.models.user import User
from app.schemas.report import AnalysisReport, ReportFacts, ReportUnavailable
from app.schemas.result import Thresholds
from app.schemas.site import ConsolidationCreate
from app.services import report as report_service
from app.services.consolidation import consolidate
from app.services.results import require_processed
from app.services.sites import get_site_or_404
from app.services.surveys import get_survey_or_404

router = APIRouter(tags=["reports"])


def _thresholds(user: User) -> Thresholds:
    return Thresholds(
        good_dbm=user.good_threshold_dbm, dead_dbm=user.dead_threshold_dbm
    )


def _survey_title(db: Session, survey: Survey) -> str:
    building = db.get(Building, survey.building_id)
    return building.name if building else "Survey"


def _markdown(report: AnalysisReport) -> Response:
    return Response(
        content=report.markdown,
        media_type="text/markdown; charset=utf-8",
        headers={
            "Content-Disposition": f'attachment; filename="report-{report.scope_id}.md"'
        },
    )


@router.get("/api/surveys/{survey_id}/report/facts", response_model=ReportFacts)
def survey_report_facts(
    survey_id: uuid.UUID,
    user=Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ReportFacts:
    survey = get_survey_or_404(db, user, survey_id)
    require_processed(survey)
    return report_service.facts_for_survey(db, survey, _survey_title(db, survey))


@router.post("/api/surveys/{survey_id}/report", response_model=AnalysisReport)
def survey_report(
    survey_id: uuid.UUID,
    format: str = Query("json", pattern="^(json|md)$"),
    user=Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AnalysisReport | Response:
    survey = get_survey_or_404(db, user, survey_id)
    require_processed(survey)
    facts = report_service.facts_for_survey(db, survey, _survey_title(db, survey))
    try:
        generated = report_service.generate(facts)
    except ReportUnavailable as exc:
        raise report_service.unavailable(exc) from exc
    return _markdown(generated) if format == "md" else generated


@router.post("/api/sites/{site_id}/report/facts", response_model=ReportFacts)
def site_report_facts(
    site_id: uuid.UUID,
    payload: ConsolidationCreate,
    user=Depends(get_current_user),
    db: Session = Depends(get_db),
) -> ReportFacts:
    site = get_site_or_404(db, user, site_id)
    result = consolidate(db, site, payload.survey_ids, user, _thresholds(user))
    return report_service.facts_for_consolidation(result, site.name)


@router.post("/api/sites/{site_id}/report", response_model=AnalysisReport)
def site_report(
    site_id: uuid.UUID,
    payload: ConsolidationCreate,
    format: str = Query("json", pattern="^(json|md)$"),
    user=Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AnalysisReport | Response:
    site = get_site_or_404(db, user, site_id)
    result = consolidate(db, site, payload.survey_ids, user, _thresholds(user))
    facts = report_service.facts_for_consolidation(result, site.name)
    try:
        generated = report_service.generate(facts)
    except ReportUnavailable as exc:
        raise report_service.unavailable(exc) from exc
    return _markdown(generated) if format == "md" else generated
