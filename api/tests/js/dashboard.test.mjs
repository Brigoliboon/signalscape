import test from 'node:test';
import assert from 'node:assert/strict';
import {
  LEVELS,
  aggregateFloors,
  boundsOf,
  buildHash,
  buildingsForSite,
  cellColor,
  cellsFromGrid,
  defaultFloor,
  findCell,
  floorChoices,
  formatArea,
  formatDbm,
  formatMeters,
  formatPct,
  gridBounds,
  levelColor,
  levelOf,
  niceScale,
  originOfFeatures,
  parseHash,
  parseInline,
  parseMarkdown,
  sceneFromFeatures,
  surveysForScope,
  toGeo,
  toLocal,
} from '../../app/static/dashboard/lib.mjs';

const thresholds = { good_dbm: -67, dead_dbm: -80 };
const ORIGIN = { lat: 14.5995, lng: 120.9842 };

test('projection matches the API projection', () => {
  const point = toGeo(0, 0, ORIGIN.lat, ORIGIN.lng);
  assert.ok(Math.abs(point.lat - ORIGIN.lat) < 1e-12);
  assert.ok(Math.abs(point.lng - ORIGIN.lng) < 1e-12);
  const east = toGeo(100, 0, ORIGIN.lat, ORIGIN.lng);
  assert.ok(east.lng > point.lng);
});

test('local metres round-trip through the projection', () => {
  const geo = toGeo(37.5, 12.25, ORIGIN.lat, ORIGIN.lng);
  const back = toLocal(geo.lat, geo.lng, ORIGIN);
  assert.ok(Math.abs(back.x - 37.5) < 1e-6);
  assert.ok(Math.abs(back.y - 12.25) < 1e-6);
});

test('signal levels use the survey thresholds and the app colours', () => {
  assert.equal(levelOf(-50, thresholds), 'good');
  assert.equal(levelOf(-67, thresholds), 'good');
  assert.equal(levelOf(-70, thresholds), 'fair');
  assert.equal(levelOf(-80, thresholds), 'fair');
  assert.equal(levelOf(-81, thresholds), 'dead');
  assert.equal(levelOf(null, thresholds), null);
  assert.equal(levelColor(-50, -67, -80), LEVELS.good.color);
  assert.equal(levelColor(-70, -67, -80), LEVELS.fair.color);
  assert.equal(levelColor(-90, -67, -80), LEVELS.dead.color);
  assert.deepEqual(
    Object.values(LEVELS).map((level) => level.label),
    ['Good', 'Weak', 'Dead'],
  );
});

test('good coverage and weak and dead zones switch independently', () => {
  assert.equal(cellColor(-50, thresholds, true, true), LEVELS.good.color);
  assert.equal(cellColor(-70, thresholds, true, true), LEVELS.fair.color);
  assert.equal(cellColor(-90, thresholds, true, true), LEVELS.dead.color);
  assert.equal(cellColor(-70, thresholds, true, false), null);
  assert.equal(cellColor(-50, thresholds, false, true), null);
  assert.equal(cellColor(null, thresholds, true, true), null);
});

test('grid bounds cover every cell', () => {
  const grid = { origin_lat: ORIGIN.lat, origin_lng: ORIGIN.lng, cell_size_m: 1, cols: 10, rows: 8 };
  const bounds = gridBounds(grid);
  assert.ok(bounds.north > bounds.south);
  assert.ok(bounds.east > bounds.west);
});

test('a grid becomes square cells in metres and skips empty ones', () => {
  const grid = {
    origin_lat: ORIGIN.lat,
    origin_lng: ORIGIN.lng,
    cell_size_m: 2,
    cols: 2,
    rows: 2,
    values: [-50, null, -72, -90],
  };
  const cells = cellsFromGrid(grid, thresholds, ORIGIN, 3);
  assert.equal(cells.length, 3);
  assert.deepEqual(cells.map((cell) => cell.level), ['good', 'fair', 'dead']);
  const first = cells[0];
  assert.ok(Math.abs(first.x1 - first.x0 - 2) < 1e-9);
  assert.ok(Math.abs(first.y1 - first.y0 - 2) < 1e-9);
  assert.equal(first.floor, 3);
  // row 1, column 0 sits two metres north of row 0.
  assert.ok(Math.abs(cells[1].y0 - 2) < 1e-9);
});

test('GeoJSON gives cells and access points, and keeps the floor', () => {
  const sw = toGeo(0, 0, ORIGIN.lat, ORIGIN.lng);
  const ne = toGeo(1, 1, ORIGIN.lat, ORIGIN.lng);
  const point = toGeo(5, 6, ORIGIN.lat, ORIGIN.lng);
  const features = [
    {
      geometry: { coordinates: [[[sw.lng, sw.lat], [ne.lng, sw.lat], [ne.lng, ne.lat], [sw.lng, ne.lat]]] },
      properties: { kind: 'coverage', rssi_dbm: -72, floor_level: 1 },
    },
    {
      geometry: { coordinates: [point.lng, point.lat] },
      properties: { kind: 'access_point', ssid: 'Campus', floor_level: 1, low_confidence: true },
    },
    { geometry: null, properties: { kind: 'access_point' } },
  ];
  const origin = originOfFeatures(features);
  assert.ok(Math.abs(origin.lat - sw.lat) < 1e-12);
  const scene = sceneFromFeatures(features, thresholds, ORIGIN);
  assert.equal(scene.cells.length, 1);
  assert.equal(scene.cells[0].level, 'fair');
  assert.equal(scene.cells[0].floor, 1);
  assert.equal(scene.pins.length, 1);
  assert.equal(scene.pins[0].low, true);
  assert.ok(Math.abs(scene.pins[0].x - 5) < 1e-6);
});

test('hit testing returns the topmost visible cell', () => {
  const cells = [
    { x0: 0, y0: 0, x1: 2, y1: 2, level: 'good' },
    { x0: 1, y0: 1, x1: 3, y1: 3, level: 'dead' },
  ];
  assert.equal(findCell(cells, 1.5, 1.5).level, 'dead');
  assert.equal(findCell(cells, 1.5, 1.5, (cell) => cell.level === 'good').level, 'good');
  assert.equal(findCell(cells, 9, 9), null);
});

test('bounds cover cells, pins and lines', () => {
  const box = boundsOf({
    cells: [{ x0: 0, y0: 0, x1: 4, y1: 2 }],
    pins: [{ x: -3, y: 5 }],
    lines: [{ ax: 0, ay: 0, bx: 9, by: -1 }],
  });
  assert.deepEqual(box, { x0: -3, y0: -1, x1: 9, y1: 5 });
  assert.equal(boundsOf({}), null);
});

test('the scale bar uses round numbers that fit', () => {
  assert.equal(niceScale(0.5).meters, 50);
  assert.equal(niceScale(0.04).meters, 2);
  assert.equal(niceScale(10).label, '1 km');
  for (const mpp of [0.013, 0.2, 0.9, 3.3, 77]) {
    const bar = niceScale(mpp, 120);
    assert.ok(bar.px <= 120 + 1e-9, `${mpp}`);
    assert.ok(bar.px > 120 / 5, `${mpp}`);
  }
  assert.equal(niceScale(0).meters, 0);
});

test('floor figures are weighted by area, not averaged', () => {
  const sum = aggregateFloors([
    { area_covered_m2: 100, good_pct: 100, fair_pct: 0, dead_pct: 0, raw_reading_count: 10, access_point_count: 1 },
    { area_covered_m2: 300, good_pct: 0, fair_pct: 50, dead_pct: 50, raw_reading_count: 5, access_point_count: 2 },
  ]);
  assert.equal(sum.area, 400);
  assert.equal(sum.good, 25);
  assert.equal(sum.fair, 37.5);
  assert.equal(sum.dead, 37.5);
  assert.equal(sum.readings, 15);
  assert.equal(sum.routers, 3);
  assert.equal(sum.hasData, true);
  const none = aggregateFloors([]);
  assert.equal(none.hasData, false);
  assert.equal(none.good, 0);
});

test('floors merge by level, and the busiest one opens first', () => {
  const choices = floorChoices([
    { floor_level: 1, floor_label: '2nd floor', area_covered_m2: 50 },
    { floor_level: 0, floor_label: 'Ground', area_covered_m2: 100 },
    { floor_level: 0, floor_label: 'Ground', area_covered_m2: 40 },
  ]);
  assert.deepEqual(choices.map((choice) => choice.level), [0, 1]);
  assert.equal(choices[0].area, 140);
  assert.equal(defaultFloor(choices), 0);
  assert.equal(defaultFloor([]), null);
});

test('numbers are formatted for reading', () => {
  assert.equal(formatDbm(-72.4), '−72 dBm');
  assert.equal(formatDbm(null), '–');
  assert.equal(formatPct(62.34), '62.3%');
  assert.equal(formatPct(0), '0%');
  assert.equal(formatPct(100), '100%');
  assert.equal(formatArea(1234.4), '1,234 m²');
  assert.equal(formatMeters(4), '4.0 m');
  assert.equal(formatMeters(34.2), '34 m');
});

test('site and building filters narrow the surveys, newest first', () => {
  const buildings = [{ id: 'a' }, { id: 'b' }, { id: 'c' }];
  const site = { building_ids: ['a', 'b'] };
  assert.deepEqual(buildingsForSite(buildings, site).map((b) => b.id), ['a', 'b']);
  assert.equal(buildingsForSite(buildings, null).length, 3);
  const surveys = [
    { id: 1, building_id: 'a', started_at: '2026-11-01T00:00:00Z' },
    { id: 2, building_id: 'b', started_at: '2026-11-20T00:00:00Z' },
    { id: 3, building_id: 'c', started_at: '2026-11-25T00:00:00Z' },
  ];
  assert.deepEqual(surveysForScope(surveys, { site }).map((s) => s.id), [2, 1]);
  assert.deepEqual(surveysForScope(surveys, { site, buildingId: 'a' }).map((s) => s.id), [1]);
  assert.deepEqual(surveysForScope(surveys, {}).map((s) => s.id), [3, 2, 1]);
});

test('the address bar keeps only known, well-formed values', () => {
  const id = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
  assert.deepEqual(parseHash(`#survey=${id}&view=3d&mode=campus`), { survey: id, view: '3d', mode: 'campus' });
  assert.deepEqual(parseHash('#survey=../../etc&view=nope&mode=x&token=secret'), {});
  assert.equal(buildHash({ survey: id, view: 'routers' }), `#survey=${id}&view=routers`);
  assert.equal(buildHash({}), '');
  assert.ok(!buildHash({ token: 'secret', survey: id }).includes('secret'));
});

test('markdown from the report becomes blocks, never HTML', () => {
  const blocks = parseMarkdown(
    '# Library\n\n## Summary\n\nSignal is **strong** here\nand fades east.\n\n- add an extender\n- move `router 3`\n\n' +
      '| Floor | Good |\n| --- | ---: |\n| G | 60% |\n\n<script>alert(1)</script>\n',
  );
  assert.deepEqual(blocks[0], { type: 'heading', level: 1, text: 'Library' });
  assert.equal(blocks[2].type, 'paragraph');
  assert.equal(blocks[2].text, 'Signal is **strong** here and fades east.');
  assert.deepEqual(blocks[3], { type: 'list', ordered: false, items: ['add an extender', 'move `router 3`'] });
  assert.equal(blocks[4].type, 'table');
  assert.deepEqual(blocks[4].header, ['Floor', 'Good']);
  assert.deepEqual(blocks[4].align, ['left', 'right']);
  assert.deepEqual(blocks[4].rows, [['G', '60%']]);
  // Markup stays text: the parser has no HTML output at all.
  assert.equal(blocks[5].type, 'paragraph');
  assert.equal(blocks[5].text, '<script>alert(1)</script>');
  assert.deepEqual(parseInline('a **b** `c` *d*').map((part) => part.type), ['text', 'strong', 'text', 'code', 'text', 'em']);
});
