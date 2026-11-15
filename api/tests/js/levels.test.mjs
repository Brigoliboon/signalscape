// Run with: node --test tests/js
import assert from 'node:assert/strict';
import test from 'node:test';

import {
  LEVEL_COLORS,
  cellAt,
  cellLevels,
  cellPixels,
  countLevels,
  dataExtent,
  floorElevation,
  formatDbm,
  hexToRgb,
  isUuid,
  legendEntries,
  levelFor,
  networkLabel,
  parseFragment,
  toLocal,
} from '../../app/static/viewer/levels.mjs';

test('levelFor uses good at or above, dead below', () => {
  assert.equal(levelFor(-67, -67, -80), 'good');
  assert.equal(levelFor(-67.1, -67, -80), 'fair');
  assert.equal(levelFor(-80, -67, -80), 'fair');
  assert.equal(levelFor(-80.1, -67, -80), 'dead');
  assert.equal(levelFor(-60, -55, -75), 'fair');
});

test('legend text comes from the API thresholds', () => {
  const entries = legendEntries({ good_dbm: -55, dead_dbm: -75 });
  assert.deepEqual(
    entries.map((e) => e.level),
    ['good', 'fair', 'dead'],
  );
  assert.equal(entries[0].text, 'Good: -55 dBm or stronger');
  assert.equal(entries[1].text, 'Fair: -75 to -55 dBm');
  assert.equal(entries[2].text, 'Dead zone: weaker than -75 dBm');
  assert.equal(entries[2].color, LEVEL_COLORS.dead);
});

test('cellLevels keeps empty cells empty and counts the rest', () => {
  const levels = cellLevels([-50, null, -70, -90, undefined], {
    good_dbm: -67,
    dead_dbm: -80,
  });
  assert.deepEqual(levels, ['good', null, 'fair', 'dead', null]);
  assert.deepEqual(countLevels(levels), { good: 1, fair: 1, dead: 1 });
});

test('cellPixels paints one RGBA pixel per cell', () => {
  const pixels = cellPixels(['good', null, 'dead'], 200);
  assert.equal(pixels.length, 12);
  assert.deepEqual([...pixels.slice(0, 4)], [...hexToRgb(LEVEL_COLORS.good), 200]);
  assert.deepEqual([...pixels.slice(4, 8)], [0, 0, 0, 0]);
  assert.deepEqual([...pixels.slice(8, 12)], [...hexToRgb(LEVEL_COLORS.dead), 200]);
  assert.deepEqual(hexToRgb('#1d4ed8'), [29, 78, 216]);
});

test('toLocal matches the API projection', () => {
  const origin = toLocal(14.5995, 120.9842, 14.5995, 120.9842);
  assert.deepEqual(origin, { x: 0, y: 0 });
  const north = toLocal(60.00001, 10, 60, 10);
  assert.ok(Math.abs(north.y - 1.11195) < 1e-4);
  const east = toLocal(60, 10.00001, 60, 10);
  assert.ok(Math.abs(east.x - 0.555975) < 1e-4);
});

test('floors are stacked at level x height, stretched for readability', () => {
  assert.equal(floorElevation(0, 3), 0);
  assert.equal(floorElevation(2, 3), 18);
  assert.equal(floorElevation(-1, 3.5, 1), -3.5);
});

test('cellAt maps texture coordinates to cells and clamps the edges', () => {
  assert.deepEqual(cellAt(0.5, 0.5, 4, 2), { col: 2, row: 1, index: 6 });
  assert.deepEqual(cellAt(0, 0, 4, 2), { col: 0, row: 0, index: 0 });
  assert.deepEqual(cellAt(1, 1, 4, 2), { col: 3, row: 1, index: 7 });
  assert.deepEqual(cellAt(-1, 2, 4, 2), { col: 0, row: 1, index: 4 });
});

test('labels', () => {
  assert.equal(formatDbm(-62), '-62 dBm');
  assert.equal(formatDbm(-62.34), '-62.3 dBm');
  assert.equal(networkLabel({ ssid: 'Lab', bssid: 'aa:bb:cc:dd:ee:01' }), 'Lab · aa:bb:cc:dd:ee:01');
  assert.equal(networkLabel({ ssid: '', bssid: 'aa:bb:cc:dd:ee:01' }), '(hidden network) · aa:bb:cc:dd:ee:01');
});

test('fragment settings need a UUID survey id and a token', () => {
  const id = '0b5f6f0e-2b0c-4a0c-9a4e-3f1d2c1b0a99';
  assert.deepEqual(parseFragment(`#survey=${id}&token=abc.def.ghi`), {
    surveyId: id,
    token: 'abc.def.ghi',
  });
  assert.equal(parseFragment(`survey=${id}`), null);
  assert.equal(parseFragment(`#survey=nope&token=abc`), null);
  assert.equal(parseFragment(`#token=abc`), null);
  assert.equal(parseFragment(''), null);
  assert.ok(isUuid(id));
  assert.ok(!isUuid('../etc/passwd'));
  assert.ok(!isUuid(null));
});

test('dataExtent is the block of cells that have data', () => {
  // 4 columns x 3 rows, south row first; data only in the middle.
  const values = [
    null, null, null, null,
    null, -60, null, null,
    null, null, -70, null,
  ];
  assert.deepEqual(dataExtent(values, 4), { col0: 1, col1: 2, row0: 1, row1: 2 });
  assert.deepEqual(dataExtent([-50], 1), { col0: 0, col1: 0, row0: 0, row1: 0 });
  assert.equal(dataExtent([null, undefined, null, null], 2), null);
  assert.equal(dataExtent([], 1), null);
});
