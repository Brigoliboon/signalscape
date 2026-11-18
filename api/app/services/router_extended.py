"""Build the extended-network list for router coverage mode."""

import uuid

from app.models.survey import Survey
from app.schemas.result import (
    ExtendedNetworkFloorOut,
    ExtendedNetworkOut,
    ExtendedRouterOut,
    RouterLinkOut,
    Thresholds,
)
from app.services import routers as rt


def links_out(trace: rt.ChainTrace) -> list[RouterLinkOut]:
    return [
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
    ]


def extended_networks(
    survey: Survey,
    thresholds: Thresholds,
    numbers: dict[str, int],
    survey_rssi: dict[str, dict[str, int]],
    floor_ssid: dict[tuple[uuid.UUID, str], dict],
    floor_id: uuid.UUID | None,
    grid_out,
) -> list[ExtendedNetworkOut]:
    """Named SSIDs served by two or more routers, with a likely main on each."""
    out = []
    for ssid, rssi in sorted(
        survey_rssi.items(), key=lambda item: (-len(item[1]), item[0])
    ):
        if len(rssi) < 2:
            continue
        floor_rows = [
            row
            for (fid, name), row in floor_ssid.items()
            if name == ssid and (floor_id is None or fid == floor_id)
        ]
        if not floor_rows:
            continue
        # Centrality comes from the floor with the most placed routers of this
        # network; scans cannot compare positions across floors.
        best_links: list[tuple[str, str, float]] = []
        best_placed: set[str] = set()
        best_count = -1
        prepared = []
        for row in sorted(floor_rows, key=lambda r: r["floor"].level):
            floor = row["floor"]
            placed = {
                m["router"].router_id: m["placed"]
                for m in row["members"]
                if m["placed"] is not None
            }
            coverage = rt.merge_max(row["grids"]) if row["grids"] else None
            trace = (
                rt.trace_chain(
                    coverage, placed, thresholds.good_dbm, thresholds.dead_dbm
                )
                if coverage is not None
                else rt.ChainTrace([], None, 0, 0)
            )
            if len(placed) > best_count:
                best_count = len(placed)
                best_placed = set(placed)
                best_links = [(link.a, link.b, link.length_m) for link in trace.links]
            prepared.append((floor, row, coverage, trace, placed))

        main = rt.likely_main(rssi, numbers, best_links, best_placed)
        floors = []
        for floor, row, coverage, trace, placed in prepared:
            routers = []
            for m in row["members"]:
                router = m["router"]
                determined = router.router_id in placed
                routers.append(
                    ExtendedRouterOut(
                        router_id=router.router_id,
                        number=router.number,
                        label=router.label,
                        role=(
                            rt.ROLE_LIKELY_MAIN
                            if router.router_id == main
                            else rt.ROLE_EXTENDER
                        ),
                        max_rssi_dbm=m["rssi"],
                        lat=router.lat if determined else None,
                        lng=router.lng if determined else None,
                        confidence=router.confidence if determined else None,
                        low_confidence=(router.low_confidence if determined else None),
                        position_determined=determined,
                    )
                )
            cell = coverage.cell if coverage is not None else 1.0
            floors.append(
                ExtendedNetworkFloorOut(
                    floor_id=floor.id,
                    floor_level=floor.level,
                    floor_label=floor.label,
                    likely_main=main,
                    routers=routers,
                    links=links_out(trace),
                    weak_cells=trace.weak_cells,
                    dead_cells=trace.dead_cells,
                    gap_area_m2=(trace.weak_cells + trace.dead_cells) * cell**2,
                    gaps=grid_out(trace.gaps, survey) if trace.gaps else None,
                    coverage=grid_out(coverage, survey) if coverage else None,
                )
            )
        out.append(
            ExtendedNetworkOut(
                ssid=ssid,
                router_ids=sorted(rssi, key=lambda r: numbers[r]),
                router_count=len(rssi),
                likely_main=main,
                floors=floors,
            )
        )
    return out
