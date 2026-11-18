"""Router coverage mode (FR-27 to FR-29). Pure math, no database access.

The strongest-signal heatmap answers "how good is the Wi-Fi here". This mode
answers "which routers are there, what does each one cover, and where does an
extended network (one name over several routers) leave a gap".

* Routers (FR-27). One radio usually serves several network names (staff,
  guest, ...) from BSSIDs that differ only in the last few bits. BSSIDs are
  grouped as one router when their first five bytes match, ignoring the
  "locally administered" bit (0x02) of the first byte, and the high nibble of
  the last byte matches: ``aa:bb:cc:dd:ee:10`` to ``aa:bb:cc:dd:ee:1f`` are one
  router. This is how most access points hand out their virtual BSSIDs, but it
  is a heuristic: two members whose estimated positions on the same floor are
  more than ``SAME_ROUTER_MAX_M`` apart are kept as separate routers.
* Footprints (FR-28). A router's footprint on a floor is the cell-by-cell
  strongest value of the per-BSSID coverage grids of its BSSIDs.
* Chains and gaps (FR-29). Routers on one floor that broadcast the same network
  name are one chain (a router and its extenders, or a mesh). The chain's
  routers are joined by the shortest set of straight links (a minimum spanning
  tree of their estimated positions). Along each link and within
  ``GAP_CORRIDOR_M`` of it, cells where the best signal of the whole chain is
  below the good threshold are gaps: weak below good, dead below dead. Cells
  nobody walked stay "no data" and are not called dead.
* Extended networks. A named SSID served by two or more routers is an
  extended network. Router mode opens on that list. One router is labelled
  "likely main" (see :data:`MAIN_HEURISTIC`); the others are extenders.
  Unplaced routers stay in the list and are left out of the drawn chain.
"""

import math
from dataclasses import dataclass, field

import numpy as np

SAME_ROUTER_MAX_M = 10.0
GAP_CORRIDOR_M = 3.0
LINK_STEP_M = 0.5

LINK_COVERED = "covered"
LINK_WEAK = "weak"
LINK_DEAD = "dead"
LINK_NO_DATA = "no_data"

GROUPING_NOTE = (
    "BSSIDs with the same first five bytes (ignoring the locally administered "
    "bit) and the same high nibble of the last byte are one router, unless their "
    f"estimated positions on one floor are more than {SAME_ROUTER_MAX_M:.0f} m "
    "apart."
)

ROLE_LIKELY_MAIN = "likely_main"
ROLE_EXTENDER = "extender"

MAIN_HEURISTIC = (
    "The likely main router is the one with the strongest reading of that "
    "network name. If two are as strong, the one closer to the middle of the "
    "chain (the shortest total distance along the links to the other placed "
    "routers) is chosen. Remaining ties use the lower router number. This is "
    "an estimate: Wi-Fi scans do not say which device is the main router or "
    "an extender."
)


def parse_mac(bssid: str) -> list[int] | None:
    parts = bssid.strip().lower().replace("-", ":").split(":")
    if len(parts) != 6:
        return None
    try:
        octets = [int(p, 16) for p in parts]
    except ValueError:
        return None
    if any(o < 0 or o > 255 for o in octets):
        return None
    return octets


def router_key(bssid: str) -> str:
    """The part of a BSSID that is the same for every BSSID of one radio."""
    octets = parse_mac(bssid)
    if octets is None:
        return bssid.lower()
    first = octets[0] & ~0x02
    middle = ":".join(f"{o:02x}" for o in octets[1:5])
    return f"{first:02x}:{middle}:{octets[5] >> 4:x}"


def _find(parent: list[int], i: int) -> int:
    while parent[i] != i:
        parent[i] = parent[parent[i]]
        i = parent[i]
    return i


def group_routers(
    bssids: list[str],
    positions: dict[str, tuple[object, float, float]] | None = None,
) -> list[list[str]]:
    """Group BSSIDs into routers (see the module notes).

    ``positions`` maps a BSSID to ``(floor_id, x, y)`` of its estimated access
    point, in local meters. Returns sorted groups, sorted by their first BSSID.
    """
    positions = positions or {}
    buckets: dict[str, list[str]] = {}
    for bssid in sorted(set(bssids)):
        buckets.setdefault(router_key(bssid), []).append(bssid)
    groups: list[list[str]] = []
    for members in buckets.values():
        parent = list(range(len(members)))

        for i in range(len(members)):
            for j in range(i + 1, len(members)):
                a = positions.get(members[i])
                b = positions.get(members[j])
                if (
                    a is not None
                    and b is not None
                    and a[0] == b[0]
                    and math.hypot(a[1] - b[1], a[2] - b[2]) > SAME_ROUTER_MAX_M
                ):
                    continue
                parent[_find(parent, j)] = _find(parent, i)
        split: dict[int, list[str]] = {}
        for i, bssid in enumerate(members):
            split.setdefault(_find(parent, i), []).append(bssid)
        groups.extend(split.values())
    return sorted(groups, key=lambda g: g[0])


@dataclass
class CellGrid:
    """Values on the survey's cell lattice: cell (col, row) of this grid is
    lattice cell (col0 + col, row0 + row), whose south-west corner is at
    ((col0 + col) * cell, (row0 + row) * cell) local meters. ``values`` has
    shape (rows, cols), south row first, ``nan`` where there is no data."""

    col0: int
    row0: int
    cell: float
    values: np.ndarray = field(repr=False)

    @property
    def rows(self) -> int:
        return int(self.values.shape[0])

    @property
    def cols(self) -> int:
        return int(self.values.shape[1])

    @classmethod
    def from_flat(
        cls,
        origin_x: float,
        origin_y: float,
        cell: float,
        cols: int,
        rows: int,
        values: list[float | None],
    ) -> "CellGrid":
        data = np.array(
            [np.nan if v is None else float(v) for v in values], dtype=float
        ).reshape(rows, cols)
        return cls(round(origin_x / cell), round(origin_y / cell), cell, data)

    def flat(self) -> list[float | None]:
        return [None if np.isnan(v) else float(v) for v in self.values.ravel()]

    def value_at(self, x: float, y: float) -> float:
        col = math.floor(x / self.cell) - self.col0
        row = math.floor(y / self.cell) - self.row0
        if 0 <= col < self.cols and 0 <= row < self.rows:
            return float(self.values[row, col])
        return math.nan

    def centers(self) -> tuple[np.ndarray, np.ndarray]:
        xs = (self.col0 + np.arange(self.cols) + 0.5) * self.cell
        ys = (self.row0 + np.arange(self.rows) + 0.5) * self.cell
        return np.meshgrid(xs, ys)


def merge_max(grids: list[CellGrid]) -> CellGrid:
    """The cell-by-cell strongest value of ``grids`` over their joint extent."""
    if not grids:
        raise ValueError("Nothing to merge")
    cell = grids[0].cell
    col0 = min(g.col0 for g in grids)
    row0 = min(g.row0 for g in grids)
    col1 = max(g.col0 + g.cols for g in grids)
    row1 = max(g.row0 + g.rows for g in grids)
    out = np.full((row1 - row0, col1 - col0), np.nan)
    for g in grids:
        r, c = g.row0 - row0, g.col0 - col0
        window = out[r : r + g.rows, c : c + g.cols]
        out[r : r + g.rows, c : c + g.cols] = np.fmax(window, g.values)
    return CellGrid(col0, row0, cell, out)


def footprint_area(grid: CellGrid, min_dbm: float) -> float:
    """Square meters of cells at or above ``min_dbm``."""
    with np.errstate(invalid="ignore"):
        cells = int((grid.values >= min_dbm).sum())
    return cells * grid.cell**2


def spanning_links(
    points: dict[str, tuple[float, float]],
) -> list[tuple[str, str]]:
    """Minimum spanning tree (Prim) of the points, as pairs of keys, grown from
    the first key (the service passes routers in number order)."""
    keys = list(points)
    if len(keys) < 2:
        return []
    inside = {keys[0]}
    links = []
    while len(inside) < len(keys):
        best = None
        for a in [k for k in keys if k in inside]:
            for b in keys:
                if b in inside:
                    continue
                d = math.dist(points[a], points[b])
                if best is None or d < best[0]:
                    best = (d, a, b)
        assert best is not None
        links.append((best[1], best[2]))
        inside.add(best[2])
    return links


def chain_centrality(
    links: list[tuple[str, str, float]], placed: list[str]
) -> dict[str, float]:
    """Total length along the chain from each placed router to the others.

    A smaller value is closer to the middle of the chain. A router that is not
    on the chain (no links to it) is left out. A lone placed router is 0."""
    if not placed:
        return {}
    adj: dict[str, list[tuple[str, float]]] = {n: [] for n in placed}
    for a, b, length in links:
        if a in adj and b in adj:
            adj[a].append((b, length))
            adj[b].append((a, length))

    def total(start: str) -> float:
        seen = {start: 0.0}
        stack = [start]
        while stack:
            node = stack.pop()
            for nxt, length in adj[node]:
                if nxt in seen:
                    continue
                seen[nxt] = seen[node] + length
                stack.append(nxt)
        return sum(seen.values())

    return {n: total(n) for n in placed}


def likely_main(
    rssi: dict[str, int],
    numbers: dict[str, int],
    links: list[tuple[str, str, float]] | None = None,
    placed: set[str] | None = None,
) -> str | None:
    """The likely main router of one network, or None when ``rssi`` is empty.

    Strongest reading of that network name first; ties go to the most central
    placed router in the chain (see :data:`MAIN_HEURISTIC`), then the lowest
    router number. Unplaced routers can still win if they are strictly
    strongest, but lose a tie to a placed, more central one.
    """
    if not rssi:
        return None
    placed = placed or set()
    centrality = chain_centrality(links or [], [r for r in rssi if r in placed])

    def key(router_id: str) -> tuple:
        centre = centrality.get(router_id, math.inf)
        return (
            -rssi[router_id],
            centre,
            numbers.get(router_id, 10**9),
            router_id,
        )

    return min(rssi, key=key)


def _segment_distance(
    px: np.ndarray, py: np.ndarray, a: tuple[float, float], b: tuple[float, float]
) -> np.ndarray:
    ax, ay = a
    dx, dy = b[0] - ax, b[1] - ay
    length2 = dx * dx + dy * dy
    if length2 == 0:
        return np.hypot(px - ax, py - ay)
    t = np.clip(((px - ax) * dx + (py - ay) * dy) / length2, 0.0, 1.0)
    return np.hypot(px - (ax + t * dx), py - (ay + t * dy))


@dataclass
class Link:
    a: str
    b: str
    length_m: float
    min_rssi_dbm: float | None
    weak_m: float
    dead_m: float
    no_data_m: float
    status: str


@dataclass
class ChainTrace:
    links: list[Link]
    gaps: CellGrid | None
    weak_cells: int
    dead_cells: int


def trace_link(
    field_grid: CellGrid,
    a: tuple[float, float],
    b: tuple[float, float],
    good_dbm: float,
    dead_dbm: float,
) -> tuple[float, float | None, float, float, float, str]:
    """Walk the straight line from ``a`` to ``b`` in steps of ``LINK_STEP_M``.

    Returns length, the weakest value on it, the meters that are weak, dead
    and without data, and a status: dead if any part is dead, else weak if any
    is weak, else no_data if nothing on it was measured, else covered."""
    length = math.dist(a, b)
    count = max(2, math.ceil(length / LINK_STEP_M) + 1)
    values = np.array(
        [
            field_grid.value_at(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
            for t in np.linspace(0.0, 1.0, count)
        ]
    )
    share = length / count
    known = values[~np.isnan(values)]
    weak = float(((known < good_dbm) & (known >= dead_dbm)).sum()) * share
    dead = float((known < dead_dbm).sum()) * share
    no_data = float(np.isnan(values).sum()) * share
    if dead > 0:
        status = LINK_DEAD
    elif weak > 0:
        status = LINK_WEAK
    elif known.size == 0:
        status = LINK_NO_DATA
    else:
        status = LINK_COVERED
    weakest = float(known.min()) if known.size else None
    return length, weakest, weak, dead, no_data, status


def trace_chain(
    field_grid: CellGrid,
    positions: dict[str, tuple[float, float]],
    good_dbm: float,
    dead_dbm: float,
) -> ChainTrace:
    """Links between the chain's placed routers and the gaps along them.

    ``field_grid`` is the best signal of the whole chain (``merge_max`` of the
    members' footprints) and ``positions`` the placed routers in local meters.
    The gap grid keeps the chain's value only on gap cells (below ``good_dbm``
    within ``GAP_CORRIDOR_M`` of a link); it is None when there is no gap."""
    pairs = spanning_links(positions)
    links = []
    near = np.zeros(field_grid.values.shape, dtype=bool)
    cx, cy = field_grid.centers()
    for a, b in pairs:
        length, weakest, weak, dead, no_data, status = trace_link(
            field_grid, positions[a], positions[b], good_dbm, dead_dbm
        )
        links.append(
            Link(
                a=a,
                b=b,
                length_m=round(length, 1),
                min_rssi_dbm=None if weakest is None else round(weakest, 1),
                weak_m=round(weak, 1),
                dead_m=round(dead, 1),
                no_data_m=round(no_data, 1),
                status=status,
            )
        )
        near |= _segment_distance(cx, cy, positions[a], positions[b]) <= (
            GAP_CORRIDOR_M
        )
    values = field_grid.values
    with np.errstate(invalid="ignore"):
        gap = near & ~np.isnan(values) & (values < good_dbm)
        dead_cells = int((gap & (values < dead_dbm)).sum())
    weak_cells = int(gap.sum()) - dead_cells
    gaps = None
    if gap.any():
        gaps = CellGrid(
            field_grid.col0,
            field_grid.row0,
            field_grid.cell,
            np.where(gap, values, np.nan),
        )
    return ChainTrace(links, gaps, weak_cells, dead_cells)
