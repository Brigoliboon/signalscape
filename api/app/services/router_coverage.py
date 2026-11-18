"""Router coverage mode of a stored survey (FR-27 to FR-29).

Reads the per-BSSID coverage grids, the access point estimates and the network
names seen, and hands them to the math in :mod:`app.services.routers`. Nothing
is stored: the mode is computed from the processed results on request.
"""

import uuid

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models.result import AccessPointEstimate, CoverageGrid
from app.models.survey import ScanReading, Survey
from app.schemas.result import (
    CellGridOut,
    RouterChainOut,
    RouterCoverageRead,
    RouterFloorOut,
    RouterLinkOut,
    RouterNetworkOut,
    RouterOut,
    Thresholds,
)
from app.services import processing as proc
from app.services import routers as rt
from app.services.results import floors_of, require_processed, thresholds_for


def _grid_out(grid: rt.CellGrid, survey: Survey) -> CellGridOut:
    south, west = proc.to_geo(
        grid.col0 * grid.cell,
        grid.row0 * grid.cell,
        survey.origin_lat,
        survey.origin_lng,
    )
    north, east = proc.to_geo(
        (grid.col0 + grid.cols) * grid.cell,
        (grid.row0 + grid.rows) * grid.cell,
        survey.origin_lat,
        survey.origin_lng,
    )
    return CellGridOut(
        origin_lat=south,
        origin_lng=west,
        north_lat=north,
        east_lng=east,
        cell_size_m=grid.cell,
        cols=grid.cols,
        rows=grid.rows,
        values=grid.flat(),
    )


def router_coverage(
    db: Session, survey: Survey, floor_id: uuid.UUID | None = None
) -> RouterCoverageRead:
    require_processed(survey)
    floors = floors_of(db, survey)

    def local(lat: float, lng: float) -> tuple[float, float]:
        return proc.to_local(lat, lng, survey.origin_lat, survey.origin_lng)

    grids: dict[tuple[uuid.UUID, str], rt.CellGrid] = {}
    thresholds = None
    for g in db.scalars(
        select(CoverageGrid).where(CoverageGrid.survey_id == survey.id)
    ):
        if thresholds is None:
            thresholds = Thresholds(
                good_dbm=g.good_threshold_dbm, dead_dbm=g.dead_threshold_dbm
            )
        if g.bssid is None:
            continue
        x, y = local(g.origin_lat, g.origin_lng)
        grids[(g.floor_id, str(g.bssid))] = rt.CellGrid.from_flat(
            x, y, g.cell_size_m, g.cols, g.rows, g.values
        )
    if thresholds is None:
        thresholds = thresholds_for(db, survey)

    estimates = {
        str(ap.bssid): ap
        for ap in db.scalars(
            select(AccessPointEstimate).where(
                AccessPointEstimate.survey_id == survey.id
            )
        )
    }
    positions = {
        bssid: (ap.floor_id, *local(ap.lat, ap.lng)) for bssid, ap in estimates.items()
    }

    # Network names and counts per floor and BSSID, from the readings.
    heard: dict[tuple[uuid.UUID, str], list[RouterNetworkOut]] = {}
    rows = db.execute(
        select(
            ScanReading.floor_id,
            ScanReading.bssid,
            ScanReading.ssid,
            func.max(ScanReading.frequency_mhz),
            func.count(),
            func.max(ScanReading.rssi_dbm),
        )
        .where(ScanReading.survey_id == survey.id)
        .group_by(ScanReading.floor_id, ScanReading.bssid, ScanReading.ssid)
    )
    for floor, bssid, ssid, frequency, count, strongest in rows:
        key = (floor, str(bssid).lower())
        if key not in grids:
            continue  # every reading of it was dropped by cleaning
        heard.setdefault(key, []).append(
            RouterNetworkOut(
                bssid=key[1],
                ssid=ssid,
                frequency_mhz=frequency,
                reading_count=count,
                max_rssi_dbm=strongest,
            )
        )

    bssids = sorted({bssid for _, bssid in grids})
    groups = rt.group_routers(bssids, positions)

    def strongest_of(group: list[str]) -> int:
        return max(
            (
                n.max_rssi_dbm
                for (_, b), nets in heard.items()
                if b in group
                for n in nets
            ),
            default=-200,
        )

    groups.sort(key=lambda g: (-strongest_of(g), g[0]))
    router_of = {b: group[0] for group in groups for b in group}
    numbers = {group[0]: i for i, group in enumerate(groups, start=1)}
    members = {group[0]: group for group in groups}

    floor_out = []
    for floor in sorted(floors.values(), key=lambda f: f.level):
        if floor_id is not None and floor.id != floor_id:
            continue
        on_floor = sorted(
            {router_of[b] for (f, b) in grids if f == floor.id},
            key=lambda r: numbers[r],
        )
        if not on_floor:
            continue
        routers = []
        footprints: dict[str, rt.CellGrid] = {}
        placed: dict[str, tuple[float, float]] = {}
        ssids_of: dict[str, set[str]] = {}
        for router_id in on_floor:
            group = [b for b in members[router_id] if (floor.id, b) in grids]
            networks = sorted(
                (n for b in group for n in heard.get((floor.id, b), [])),
                key=lambda n: (-n.max_rssi_dbm, n.bssid, n.ssid),
            )
            footprint = rt.merge_max([grids[(floor.id, b)] for b in group])
            footprints[router_id] = footprint
            here = [
                estimates[b]
                for b in members[router_id]
                if b in estimates and estimates[b].floor_id == floor.id
            ]
            best = max(
                here, key=lambda ap: (ap.max_rssi_dbm, ap.reading_count), default=None
            )
            if best is not None:
                placed[router_id] = local(best.lat, best.lng)
            ssids = sorted({n.ssid for n in networks})
            ssids_of[router_id] = {s for s in ssids if s}
            routers.append(
                RouterOut(
                    router_id=router_id,
                    number=numbers[router_id],
                    label=f"Router {numbers[router_id]}",
                    ssids=ssids,
                    networks=networks,
                    max_rssi_dbm=max((n.max_rssi_dbm for n in networks), default=-200),
                    lat=best.lat if best else None,
                    lng=best.lng if best else None,
                    confidence=best.confidence if best else None,
                    low_confidence=best.low_confidence if best else None,
                    area_m2=rt.footprint_area(footprint, thresholds.dead_dbm),
                    good_area_m2=rt.footprint_area(footprint, thresholds.good_dbm),
                    footprint=_grid_out(footprint, survey),
                )
            )

        # Chains: routers sharing a (named) network on this floor. Names served
        # by the same routers are one chain.
        by_ssid: dict[str, set[str]] = {}
        for router_id, names in ssids_of.items():
            for name in names:
                by_ssid.setdefault(name, set()).add(router_id)
        chains_by_members: dict[tuple[str, ...], list[str]] = {}
        for name, ids in sorted(by_ssid.items()):
            if len(ids) >= 2:
                key = tuple(sorted(ids, key=lambda r: numbers[r]))
                chains_by_members.setdefault(key, []).append(name)
        chains = []
        for ids, names in chains_by_members.items():
            field_grid = rt.merge_max([footprints[r] for r in ids])
            trace = rt.trace_chain(
                field_grid,
                {r: placed[r] for r in ids if r in placed},
                thresholds.good_dbm,
                thresholds.dead_dbm,
            )
            chains.append(
                RouterChainOut(
                    ssids=names,
                    router_ids=list(ids),
                    links=[
                        RouterLinkOut(
                            from_router=link.a,
                            to_router=link.b,
                            length_m=link.length_m,
                            min_rssi_dbm=link.min_rssi_dbm,
                            weak_m=link.weak_m,
                            dead_m=link.dead_m,
                            no_data_m=link.no_data_m,
                            status=link.status,
                        )
                        for link in trace.links
                    ],
                    weak_cells=trace.weak_cells,
                    dead_cells=trace.dead_cells,
                    gap_area_m2=(trace.weak_cells + trace.dead_cells)
                    * field_grid.cell**2,
                    gaps=_grid_out(trace.gaps, survey) if trace.gaps else None,
                )
            )
        chains.sort(key=lambda c: (-len(c.router_ids), c.ssids))
        floor_out.append(
            RouterFloorOut(
                floor_id=floor.id,
                floor_level=floor.level,
                floor_label=floor.label,
                router_count=len(routers),
                routers=routers,
                chains=chains,
            )
        )
    return RouterCoverageRead(
        survey_id=survey.id,
        thresholds=thresholds,
        router_count=len(groups),
        bssid_count=len(bssids),
        grouping=rt.GROUPING_NOTE,
        gap_corridor_m=rt.GAP_CORRIDOR_M,
        floors=floor_out,
    )
