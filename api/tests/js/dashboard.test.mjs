import test from 'node:test';
import assert from 'node:assert/strict';
import {
  cellColor,
  gridBounds,
  levelColor,
  toGeo,
} from '../../app/static/dashboard/dashboard.mjs';

const thresholds = { good_dbm: -67, dead_dbm: -80 };

test('projection matches the API projection', () => {
  const point = toGeo(0, 0, 14.5995, 120.9842);
  assert.ok(Math.abs(point.lat - 14.5995) < 1e-12);
  assert.ok(Math.abs(point.lng - 120.9842) < 1e-12);
  const east = toGeo(100, 0, 14.5995, 120.9842);
  assert.ok(east.lng > point.lng);
});

test('signal levels use the survey thresholds', () => {
  assert.equal(levelColor(-50, -67, -80), '#16a34a');
  assert.equal(levelColor(-70, -67, -80), '#d97706');
  assert.equal(levelColor(-90, -67, -80), '#dc2626');
});

test('the dead and weak layer can replace the heatmap', () => {
  assert.equal(cellColor(-50, thresholds, true, true), '#16a34a');
  assert.equal(cellColor(-70, thresholds, true, true), '#d97706');
  assert.equal(cellColor(-90, thresholds, true, true), '#dc2626');
  assert.equal(cellColor(-70, thresholds, true, false), null);
  assert.equal(cellColor(-50, thresholds, false, true), null);
  assert.equal(cellColor(null, thresholds, true, true), null);
});

test('grid bounds cover every cell', () => {
  const grid = {
    origin_lat: 14.5995,
    origin_lng: 120.9842,
    cell_size_m: 1,
    cols: 10,
    rows: 8,
  };
  const bounds = gridBounds(grid);
  assert.ok(bounds.north > bounds.south);
  assert.ok(bounds.east > bounds.west);
  assert.ok(bounds.south <= grid.origin_lat + 1e-12);
  assert.ok(bounds.west <= grid.origin_lng + 1e-12);
});
