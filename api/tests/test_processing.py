"""Unit tests for the pure processing math, on small known inputs."""

import math
import uuid

import numpy as np
import pytest

from app.services import processing as proc
from app.services.processing import Reading

FLOOR = uuid.uuid4()
OTHER_FLOOR = uuid.uuid4()
BSSID = "aa:bb:cc:dd:ee:01"


def r(
    x: float = 0.0,
    y: float = 0.0,
    rssi: float = -60,
    *,
    t: float = 0.0,
    bssid: str = BSSID,
    floor: uuid.UUID = FLOOR,
    ssid: str = "net",
    freq: int = 2437,
) -> Reading:
    return Reading(floor, bssid, ssid, freq, x, y, rssi, t)


# --- projection -------------------------------------------------------------


def test_projection_round_trip() -> None:
    lat0, lng0 = 14.5995, 120.9842
    x, y = proc.to_local(14.6001, 120.9850, lat0, lng0)
    lat, lng = proc.to_geo(x, y, lat0, lng0)
    assert lat == pytest.approx(14.6001, abs=1e-9)
    assert lng == pytest.approx(120.9850, abs=1e-9)


def test_projection_known_distances() -> None:
    lat0, lng0 = 60.0, 10.0
    x, y = proc.to_local(lat0 + 0.00001, lng0, lat0, lng0)
    assert (x, y) == pytest.approx((0.0, 1.11195), abs=1e-4)
    # one degree of longitude is half as long at 60 degrees north
    x, _ = proc.to_local(lat0, lng0 + 0.00001, lat0, lng0)
    assert x == pytest.approx(0.555975, abs=1e-4)
    assert proc.to_local(lat0, lng0, lat0, lng0) == (0.0, 0.0)


# --- cleaning: range --------------------------------------------------------


def test_range_check_drops_values_outside_minus100_to_minus20() -> None:
    readings = [
        r(0, 0, -101, t=0),
        r(10, 0, -100, t=1),
        r(20, 0, -20, t=2),
        r(30, 0, -19, t=3),
        r(40, 0, 0, t=4),
    ]
    cleaned, stats = proc.clean_readings(readings)
    assert sorted(c.rssi for c in cleaned) == [-100, -20]
    assert stats.raw == 5
    assert stats.out_of_range == 3
    assert stats.kept == 2


def test_range_check_drops_unusable_bssids() -> None:
    readings = [
        r(bssid="00:00:00:00:00:00"),
        r(bssid="ff:ff:ff:ff:ff:ff"),
        r(bssid=BSSID),
    ]
    cleaned, stats = proc.clean_readings(readings)
    assert [c.bssid for c in cleaned] == [BSSID]
    assert stats.out_of_range == 2


# --- cleaning: merging repeat scans ----------------------------------------


def test_repeat_scans_merge_to_median() -> None:
    readings = [
        r(0.0, 0.0, -60, t=0),
        r(0.4, 0.0, -70, t=5),
        r(0.0, 0.6, -66, t=9),
    ]
    merged = proc.merge_repeats(readings)
    assert len(merged) == 1
    assert merged[0].rssi == -66
    assert merged[0].x == pytest.approx(0.4 / 3)
    assert merged[0].y == pytest.approx(0.2)
    assert merged[0].t == 0


def test_even_count_merge_uses_the_middle_pair_average() -> None:
    merged = proc.merge_repeats([r(t=0, rssi=-60), r(t=1, rssi=-70)])
    assert [m.rssi for m in merged] == [-65]


def test_scans_more_than_10_seconds_apart_do_not_merge() -> None:
    merged = proc.merge_repeats([r(t=0), r(t=10.5)])
    assert len(merged) == 2
    # exactly 10 s still merges
    assert len(proc.merge_repeats([r(t=0), r(t=10)])) == 1


def test_scans_more_than_1_meter_apart_do_not_merge() -> None:
    assert len(proc.merge_repeats([r(0, 0, t=0), r(1.5, 0, t=1)])) == 2
    assert len(proc.merge_repeats([r(0, 0, t=0), r(1.0, 0, t=1)])) == 1


def test_merging_keeps_networks_and_floors_apart() -> None:
    readings = [
        r(t=0),
        r(t=1, bssid="aa:bb:cc:dd:ee:02"),
        r(t=2, floor=OTHER_FLOOR),
    ]
    assert len(proc.merge_repeats(readings)) == 3


def test_merge_clusters_use_the_first_scan_as_anchor() -> None:
    # The third scan is 1.6 m from the first, so it starts a new cluster even
    # though it is within 1 m of the second.
    readings = [r(0.0, t=0), r(0.8, t=1), r(1.6, t=2)]
    merged = proc.merge_repeats(readings)
    assert len(merged) == 2


# --- cleaning: outliers -----------------------------------------------------


def spread(rssis: list[float], step: float = 0.5) -> list[Reading]:
    """Readings 0.5 m apart, far enough in time not to merge."""
    return [r(i * step * 2, 0, v, t=i * 100) for i, v in enumerate(rssis)]


def test_outlier_far_from_neighborhood_median_is_dropped() -> None:
    readings = spread([-60, -61, -59, -60, -62, -90])
    kept = proc.remove_outliers(readings)
    assert -90 not in [k.rssi for k in kept]
    assert len(kept) == 5


def test_mad_zero_does_not_drop_small_differences() -> None:
    readings = spread([-60, -60, -60, -60, -62])
    kept = proc.remove_outliers(readings)
    assert len(kept) == 5  # MAD is 0, a 2 dB gap is within 2.5 x the 2 dB floor


def test_mad_zero_still_drops_big_differences() -> None:
    readings = spread([-60, -60, -60, -60, -75])
    kept = proc.remove_outliers(readings)
    assert sorted(k.rssi for k in kept) == [-60, -60, -60, -60]


def test_isolated_readings_are_kept() -> None:
    # Two points 2 m apart have fewer than 3 neighbors each.
    readings = [r(0, 0, -50, t=0), r(2, 0, -95, t=100)]
    assert len(proc.remove_outliers(readings)) == 2
    # Far apart points are not neighbors at all.
    far = [r(0, 0, -50, t=0), r(100, 0, -95, t=100), r(200, 0, -70, t=200)]
    assert len(proc.remove_outliers(far)) == 3


def test_outliers_are_judged_per_network_and_floor() -> None:
    mine = spread([-60, -61, -59, -60])
    other_network = [r(x.x, x.y, -95, t=x.t, bssid="aa:bb:cc:dd:ee:02") for x in mine]
    other_floor = [r(x.x, x.y, -95, t=x.t, floor=OTHER_FLOOR) for x in mine]
    kept = proc.remove_outliers(mine + other_network + other_floor)
    assert len(kept) == 12


def test_neighborhood_radius_is_3_meters() -> None:
    # The -90 reading is 3.5 m from the others, so it has no neighborhood to
    # disagree with (fewer than 3 neighbors).
    readings = [
        r(0, 0, -60, t=0),
        r(1, 0, -61, t=100),
        r(2, 0, -59, t=200),
        r(5.5, 0, -90, t=300),
    ]
    assert len(proc.remove_outliers(readings)) == 4


def test_clean_readings_runs_every_step_and_reports_counts() -> None:
    readings = [
        r(0, 0, -120, t=0),  # out of range
        r(0, 0, -60, t=1),
        r(0.2, 0, -62, t=2),  # merges with the previous one
        r(2, 0, -61, t=100),
        r(4, 0, -60, t=200),
        r(6, 0, -62, t=300),
        r(3, 1, -95, t=400),  # outlier among its neighbors
    ]
    cleaned, stats = proc.clean_readings(readings)
    assert stats.raw == 7
    assert stats.out_of_range == 1
    assert stats.merged == 1
    assert stats.outliers == 1
    assert stats.kept == len(cleaned) == 4
    assert [c.t for c in cleaned] == sorted(c.t for c in cleaned)


def test_clean_readings_with_nothing() -> None:
    cleaned, stats = proc.clean_readings([])
    assert cleaned == []
    assert stats == proc.CleaningStats()


def test_neighbor_search_blocks_give_the_same_answer(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    xy = np.array([[0.0, 0.0], [1.0, 0.0], [5.0, 0.0], [5.5, 0.0]])
    expected = [list(n) for n in proc._neighbors(xy, 3.0)]
    monkeypatch.setattr(proc, "_CHUNK_ELEMENTS", 4)  # one row per block
    assert (
        [list(n) for n in proc._neighbors(xy, 3.0)]
        == expected
        == [
            [0, 1],
            [0, 1],
            [2, 3],
            [2, 3],
        ]
    )


# --- strongest signal -------------------------------------------------------


def test_strongest_per_position_takes_the_best_network() -> None:
    readings = [
        r(0.1, 0.1, -70, bssid="aa:bb:cc:dd:ee:01"),
        r(0.2, 0.2, -55, bssid="aa:bb:cc:dd:ee:02"),
        r(10, 10, -80, bssid="aa:bb:cc:dd:ee:01"),
        r(0.1, 0.1, -40, floor=OTHER_FLOOR),
    ]
    best = proc.strongest_per_position(readings)
    by_pos = {(round(b.x), round(b.y), b.floor_id): b for b in best}
    assert len(best) == 3
    assert by_pos[(0, 0, FLOOR)].rssi == -55
    assert by_pos[(0, 0, FLOOR)].bssid == "aa:bb:cc:dd:ee:02"
    assert by_pos[(0, 0, FLOOR)].x == pytest.approx(0.15)
    assert by_pos[(10, 10, FLOOR)].rssi == -80
    assert by_pos[(0, 0, OTHER_FLOOR)].rssi == -40


# --- IDW --------------------------------------------------------------------


def cell(grid: proc.Grid, col: int, row: int) -> float:
    return float(grid.values[row * grid.cols + col])


def test_idw_needs_readings() -> None:
    with pytest.raises(proc.ProcessingError):
        proc.idw_grid([])


def test_idw_single_reading_fills_radius_only() -> None:
    grid = proc.idw_grid([r(0.5, 0.5, -60)])
    assert (grid.cols, grid.rows) == (1, 1)
    assert (grid.origin_x, grid.origin_y) == (0.0, 0.0)
    assert cell(grid, 0, 0) == -60.0  # the cell center is the reading


def test_idw_grid_extent_and_radius() -> None:
    grid = proc.idw_grid([r(0.5, 0.5, -60), r(14.5, 0.5, -70)])
    assert (grid.cols, grid.rows) == (15, 1)
    # cell centers 0.5 .. 14.5; reading A reaches cells up to x = 10.5 and
    # reading B down to x = 4.5, so every cell is covered
    assert not np.isnan(grid.values).any()
    # a cell more than 10 m from both stays empty
    wide = proc.idw_grid([r(0.5, 0.5, -60), r(30.5, 0.5, -70)])
    assert math.isnan(cell(wide, 15, 0))
    assert not math.isnan(cell(wide, 10, 0))  # 9.5 m from A
    assert math.isnan(cell(wide, 11, 0))  # 10.5 m from A, 19.5 m from B


def test_idw_weights_by_inverse_square_distance() -> None:
    # Cell center (2.5, 0.5) is 2 m from A at (0.5, 0.5) and 1 m from B at
    # (3.5, 0.5), so the weights are 1/4 and 1: (-50/4 + -70) / (1/4 + 1) = -66.
    grid = proc.idw_grid([r(0.5, 0.5, -50), r(3.5, 0.5, -70)])
    assert cell(grid, 2, 0) == pytest.approx(-66.0)
    # a cell on a reading takes its exact value
    assert cell(grid, 0, 0) == -50.0
    assert cell(grid, 3, 0) == -70.0


def test_idw_exact_hits_average_when_readings_share_a_cell_center() -> None:
    grid = proc.idw_grid([r(0.5, 0.5, -50), r(0.5, 0.5, -60)])
    assert cell(grid, 0, 0) == pytest.approx(-55.0)


def test_idw_row_major_order_south_row_first() -> None:
    grid = proc.idw_grid([r(0.5, 0.5, -50), r(0.5, 2.5, -80)])
    assert (grid.cols, grid.rows) == (1, 3)
    assert cell(grid, 0, 0) == -50.0
    assert cell(grid, 0, 2) == -80.0
    assert cell(grid, 0, 1) == pytest.approx(-65.0)


def test_idw_handles_negative_coordinates() -> None:
    grid = proc.idw_grid([r(-3.2, -1.1, -60), r(-1.0, 0.2, -60)])
    assert grid.origin_x == -4.0
    assert grid.origin_y == -2.0
    assert (grid.cols, grid.rows) == (4, 3)


def test_idw_refuses_huge_extents() -> None:
    with pytest.raises(proc.ProcessingError, match="span"):
        proc.idw_grid([r(0, 0), r(5000, 0)])
    with pytest.raises(proc.ProcessingError):
        proc.idw_grid([r(0, 0), r(0, 5000)])


def test_idw_blocks_give_the_same_answer(monkeypatch: pytest.MonkeyPatch) -> None:
    readings = [r(0.5, 0.5, -50), r(6.5, 3.5, -70), r(2.5, 2.5, -61)]
    expected = proc.idw_grid(readings).values.copy()
    monkeypatch.setattr(proc, "_CHUNK_ELEMENTS", 3)  # one cell per block
    again = proc.idw_grid(readings).values
    np.testing.assert_allclose(again, expected, equal_nan=True)


def test_idw_for_one_floor_under_the_time_budget() -> None:
    """NFR-1: a few thousand readings for one floor in well under 30 s."""
    import time

    rng = np.random.default_rng(1)
    readings = [
        r(float(x), float(y), float(v), t=i)
        for i, (x, y, v) in enumerate(
            zip(
                rng.uniform(0, 60, 3000),
                rng.uniform(0, 40, 3000),
                rng.uniform(-90, -40, 3000),
                strict=True,
            )
        )
    ]
    started = time.monotonic()
    grid = proc.idw_grid(readings)
    assert time.monotonic() - started < 30
    assert (grid.cols, grid.rows) == (60, 40)


# --- levels -----------------------------------------------------------------


def test_level_boundaries() -> None:
    assert proc.level_for(-67, -67, -80) == "good"
    assert proc.level_for(-66.9, -67, -80) == "good"
    assert proc.level_for(-67.1, -67, -80) == "fair"
    assert proc.level_for(-80, -67, -80) == "fair"
    assert proc.level_for(-80.1, -67, -80) == "dead"
    assert proc.level_for(-60, -55, -75) == "fair"  # custom thresholds


def test_level_shares_ignore_empty_cells() -> None:
    values = np.array([-50, -67, -70, -80, -85, np.nan, np.nan])
    good, fair, dead = proc.level_shares(values, -67, -80)
    assert (good, fair, dead) == pytest.approx((40.0, 40.0, 20.0))
    assert proc.covered_cells(values) == 5
    assert proc.level_shares(np.array([np.nan]), -67, -80) == (0.0, 0.0, 0.0)


def test_grid_cell_corners() -> None:
    grid = proc.Grid(-4.0, -2.0, 4, 3, 1.0, np.zeros(12))
    assert proc.grid_cell_corners(grid, 1, 2) == ((-3.0, 0.0), (-2.0, 1.0))


# --- access points ----------------------------------------------------------


def test_access_point_is_the_power_weighted_centroid() -> None:
    # equal strength: the midpoint
    mid = proc.estimate_access_points([r(0, 0, -50), r(10, 0, -50)])[0]
    assert (mid.x, mid.y) == pytest.approx((5.0, 0.0))
    # -50 vs -60 dBm is a 10x power ratio: x = 10 * 10 / 11
    skew = proc.estimate_access_points([r(0, 0, -50, t=0), r(10, 0, -60, t=1)])[0]
    assert skew.x == pytest.approx(10 / 11)
    assert skew.reading_count == 2
    assert skew.max_rssi_dbm == -50


def test_access_point_uses_only_the_ten_strongest_readings() -> None:
    strong = [r(float(i), 0, -50, t=i) for i in range(10)]
    weak = r(1000, 0, -90, t=99)
    ap = proc.estimate_access_points([*strong, weak])[0]
    # the weak far reading is excluded (it would drag x towards 1000 otherwise)
    assert ap.x == pytest.approx(4.5, abs=1e-6)
    assert ap.reading_count == 11


def test_access_point_floor_is_where_its_strongest_reading_is() -> None:
    readings = [
        r(0, 0, -45, floor=FLOOR, t=0, ssid="lobby", freq=5180),
        r(2, 0, -47, floor=FLOOR, t=1),
        r(50, 50, -70, floor=OTHER_FLOOR, t=2),
    ]
    ap = proc.estimate_access_points(readings)[0]
    assert ap.floor_id == FLOOR
    assert ap.ssid == "lobby"
    assert ap.frequency_mhz == 5180
    assert ap.reading_count == 2  # readings on its own floor only
    assert ap.x < 2


def test_access_points_per_bssid_in_stable_order() -> None:
    readings = [
        r(0, 0, -60, bssid="aa:bb:cc:dd:ee:02"),
        r(5, 5, -50, bssid="aa:bb:cc:dd:ee:01"),
    ]
    aps = proc.estimate_access_points(readings)
    assert [a.bssid for a in aps] == ["aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"]
    assert proc.estimate_access_points([]) == []


def test_access_point_rounds_the_strongest_value() -> None:
    merged_median = r(0, 0, -64.5)
    assert proc.estimate_access_points([merged_median])[0].max_rssi_dbm in (-64, -65)
