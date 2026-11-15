"""Shared pagination and sorting for list endpoints (FR-3b).

Usage in a route::

    sort_dep = sort_param({"name": Item.name, "created_at": Item.created_at})

    @router.get("/items", response_model=Page[ItemRead])
    def list_items(
        page: PageParams = Depends(pagination_params),
        order_by: list[ColumnElement] = Depends(sort_dep),
        db: Session = Depends(get_db),
    ):
        return paginate(db, select(Item).where(...), page, order_by)
"""

from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from fastapi import HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import ColumnElement, Select, func, select
from sqlalchemy.orm import Session

DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100


class Page[T](BaseModel):
    items: list[T]
    total: int
    page: int
    page_size: int


@dataclass
class PageParams:
    page: int
    page_size: int

    @property
    def offset(self) -> int:
        return (self.page - 1) * self.page_size


def pagination_params(
    page: int = Query(1, ge=1, description="1-based page number"),
    page_size: int = Query(
        DEFAULT_PAGE_SIZE,
        ge=1,
        le=MAX_PAGE_SIZE,
        description=f"Items per page (max {MAX_PAGE_SIZE})",
    ),
) -> PageParams:
    return PageParams(page=page, page_size=page_size)


def sort_param(
    allowed: Mapping[str, ColumnElement[Any]],
    default: str,
    tie_breaker: ColumnElement[Any] | None = None,
) -> Callable[..., list[ColumnElement[Any]]]:
    """Build a dependency that parses ``?sort=field`` or ``?sort=-field``.

    ``allowed`` maps public field names to columns. ``default`` is used when the
    parameter is missing. ``tie_breaker`` (usually the primary key) is appended so
    pages are stable when the sort values repeat.
    """
    names = ", ".join(sorted(allowed))

    def dependency(
        sort: str = Query(
            default,
            description=f"Field to sort by; prefix with '-' for descending. "
            f"One of: {names}",
        ),
    ) -> list[ColumnElement[Any]]:
        descending = sort.startswith("-")
        field = sort[1:] if descending else sort
        column = allowed.get(field)
        if column is None:
            raise HTTPException(
                status_code=422,
                detail=f"Cannot sort by '{field}'. Allowed fields: {names}",
            )
        clauses = [column.desc() if descending else column.asc()]
        if tie_breaker is not None:
            clauses.append(tie_breaker.asc())
        return clauses

    return dependency


def paginate(
    db: Session,
    stmt: Select[Any],
    params: PageParams,
    order_by: Sequence[ColumnElement[Any]],
) -> dict[str, Any]:
    """Run ``stmt`` (a select of one ORM entity) for one page.

    Returns a dict shaped like :class:`Page`, so it can be returned straight from
    a route that declares ``response_model=Page[Schema]``.
    """
    total = db.scalar(select(func.count()).select_from(stmt.order_by(None).subquery()))
    items = db.scalars(
        stmt.order_by(*order_by).limit(params.page_size).offset(params.offset)
    ).all()
    return {
        "items": list(items),
        "total": total or 0,
        "page": params.page,
        "page_size": params.page_size,
    }
