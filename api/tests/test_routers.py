"""Router coverage maths (FR-27 to FR-29): grouping, footprints, chain gaps."""

import math
import uuid

import numpy as np
import pytest

from app.services import routers as rt

F1 = uuid.uuid4()
F2 = uuid.uuid4()


def test_router_key_ignores_last_nibble_and_local_bit() -> None:
    assert rt.router_key("AA:BB:CC:DD:EE:10") == rt.router_key("aa:bb:cc:dd:ee:1f")
    assert rt.router_key("aa:bb:cc:dd:ee:10") != rt.router_key("aa:bb:cc:dd:ee:20")
    # a locally administered virtual BSSID of the same radio
    assert rt.router_key("02:bb:cc:dd:ee:11") == rt.router_key("00:bb:cc:dd:ee:12")
    assert rt.router_key("aa:bb:cc:dd:ef:10") != rt.router_key("aa:bb:cc:dd:ee:10")
    assert rt.router_key("not-a-mac") == "not-a-mac"
    assert rt.parse_mac("aa:bb:cc:dd:ee") is None
    assert rt.parse_mac("aa:bb:cc:dd:ee:zz") is None


def test_one_radio_with_two_names_is_one_router() -> None:
    groups = rt.group_routers(
        ["aa:bb:cc:dd:ee:11", "aa:bb:cc:dd:ee:10", "11:22:33:44:55:60"]
    )
    assert groups == [
        ["11:22:33:44:55:60"],
        ["aa:bb:cc:dd:ee:10", "aa:bb:cc:dd:ee:11"],
    ]


def test_far_apart_members_stay_separate_routers() -> None:
    a, b, c = "aa:bb:cc:dd:ee:10", "aa:bb:cc:dd:ee:11", "aa:bb:cc:dd:ee:12"
    positions = {a: (F1, 0.0, 0.0), b: (F1, 30.0, 0.0), c: (F1, 2.0, 0.0)}
    assert rt.group_routers([a, b, c], positions) == [[a, c], [b]]
    # placed on different floors: cannot compare, so grouped
    positions = {a: (F1, 0.0, 0.0), b: (F2, 30.0, 0.0)}
    assert rt.group_routers([a, b], positions) == [[a, b]]


def grid(col0: int, row0: int, rows: list[list[float | None]]) -> rt.CellGrid:
    values = np.array([[np.nan if v is None else v for v in r] for r in rows])
    return rt.CellGrid(col0, row0, 1.0, values)


def test_merge_max_aligns_grids_on_the_lattice() -> None:
    a = grid(0, 0, [[-50, -60]])
    b = grid(1, 0, [[-55, None], [-70, -80]])
    merged = rt.merge_max([a, b])
    assert (merged.col0, merged.row0, merged.cols, merged.rows) == (0, 0, 3, 2)
    assert merged.flat() == [-50, -55, None, None, -70, -80]
    assert rt.footprint_area(merged, -60) == 2
    with pytest.raises(ValueError):
        rt.merge_max([])


def test_from_flat_rounds_the_origin_onto_the_lattice() -> None:
    g = rt.CellGrid.from_flat(2.0000001, -3.0, 1.0, 2, 1, [-50, None])
    assert (g.col0, g.row0) == (2, -3)
    assert g.value_at(2.5, -2.5) == -50
    assert math.isnan(g.value_at(3.5, -2.5))
    assert math.isnan(g.value_at(10, 10))


def test_spanning_links_join_every_router_by_the_shortest_links() -> None:
    points = {"a": (0.0, 0.0), "b": (10.0, 0.0), "c": (11.0, 0.0)}
    assert rt.spanning_links(points) == [("a", "b"), ("b", "c")]
    assert rt.spanning_links({"a": (0.0, 0.0)}) == []


def corridor(values: list[float | None]) -> rt.CellGrid:
    """A 1-cell wide corridor along x, three rows so the corridor has sides."""
    row = [values]
    return grid(0, 0, row * 3)


def test_chain_gap_between_two_routers_is_found() -> None:
    # Strong at both ends, weak then dead in the middle, one unwalked cell.
    values = [-45, -55, -62, -72, -85, -90, None, -88, -74, -60, -50]
    field_grid = corridor(values)
    trace = rt.trace_chain(
        field_grid, {"r1": (0.5, 1.5), "r2": (10.5, 1.5)}, good_dbm=-67, dead_dbm=-80
    )
    [link] = trace.links
    assert (link.a, link.b) == ("r1", "r2")
    assert link.status == rt.LINK_DEAD
    assert link.length_m == 10.0
    assert link.min_rssi_dbm == -90
    assert link.dead_m > 0 and link.weak_m > 0 and link.no_data_m > 0
    assert trace.dead_cells == 3 * 3
    assert trace.weak_cells == 2 * 3
    gaps = trace.gaps
    assert gaps is not None
    middle = gaps.values[1]
    assert np.isnan(middle[0]) and np.isnan(middle[10])  # good ends are not gaps
    assert np.isnan(middle[6])  # no data is not called dead
    assert middle[5] == -90


def test_gap_only_counts_cells_near_the_links() -> None:
    # Dead cells far from the line between the routers are not chain gaps.
    rows = [[-50.0] * 5 for _ in range(10)]
    rows[9] = [-95.0] * 5  # 8.5 m north of the link
    field_grid = grid(0, 0, rows)
    trace = rt.trace_chain(field_grid, {"a": (0.5, 0.5), "b": (4.5, 0.5)}, -67, -80)
    assert trace.links[0].status == rt.LINK_COVERED
    assert trace.gaps is None
    assert trace.dead_cells == 0 and trace.weak_cells == 0


def test_link_without_data_and_chain_without_placed_routers() -> None:
    field_grid = grid(0, 0, [[None, None, None]])
    length, weakest, weak, dead, no_data, status = rt.trace_link(
        field_grid, (0.5, 0.5), (2.5, 0.5), -67, -80
    )
    assert status == rt.LINK_NO_DATA and weakest is None
    assert weak == dead == 0 and no_data == pytest.approx(length)
    weak_only = grid(0, 0, [[-50, -70, -50]])
    assert rt.trace_link(weak_only, (0.5, 0.5), (2.5, 0.5), -67, -80)[-1] == (
        rt.LINK_WEAK
    )
    trace = rt.trace_chain(field_grid, {"a": (0.5, 0.5)}, -67, -80)
    assert trace.links == [] and trace.gaps is None
    same_place = rt.trace_chain(weak_only, {"a": (1.5, 0.5), "b": (1.5, 0.5)}, -67, -80)
    assert same_place.links[0].length_m == 0
    assert same_place.weak_cells == 1
