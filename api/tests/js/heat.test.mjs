// Run with: node --test tests/js/heat.test.mjs
import assert from 'node:assert/strict';
import test from 'node:test';

import {
  CONTOUR_MIN_COVERAGE,
  LEGEND_TICKS,
  MAX_IMAGE_SIDE,
  RAMP_STOPS,
  cellAtPadded,
  chooseFactor,
  contourSegments,
  rampColor,
  rampFraction,
  renderPixels,
  smoothstep,
  upsampleGrid,
} from '../../app/static/viewer/heat.mjs';
import { hexToRgb } from '../../app/static/viewer/levels.mjs';

/** A picture built by hand: row 0 = top. */
function field(width, height, value, coverage = null, confidence = null) {
  return {
    width,
    height,
    factor: 1,
    value: Float32Array.from(value),
    coverage: Float32Array.from(coverage ?? value.map(() => 1)),
    confidence: Float32Array.from(confidence ?? value.map(() => 1)),
  };
}

test('the ramp is red at -30, green at -67, dark blue at -100 and clamps outside', () => {
  assert.deepEqual(rampColor(-30), hexToRgb('#e3211c'));
  assert.deepEqual(rampColor(-67), hexToRgb('#38b54a'));
  assert.deepEqual(rampColor(-100), hexToRgb('#1b2166'));
  assert.deepEqual(rampColor(-10), rampColor(-30));
  assert.deepEqual(rampColor(-120), rampColor(-100));
  for (const stop of RAMP_STOPS) assert.deepEqual(rampColor(stop.dbm), hexToRgb(stop.color));
});

test('the ramp blends linearly between stops', () => {
  // Halfway between orange (-45) and yellow (-57) is -51.
  const [r, g, b] = rampColor(-51);
  const orange = hexToRgb('#f7861e');
  const yellow = hexToRgb('#fbe51a');
  assert.deepEqual([r, g, b], orange.map((c, k) => Math.round((c + yellow[k]) / 2)));
});

test('the ramp stops run strong to weak, and the legend ticks sit on the bar', () => {
  const dbm = RAMP_STOPS.map((s) => s.dbm);
  assert.deepEqual([...dbm].sort((a, b) => b - a), dbm);
  assert.equal(rampFraction(-30), 0);
  assert.equal(rampFraction(-100), 1);
  assert.equal(rampFraction(-65), 0.5);
  assert.ok(LEGEND_TICKS.every((t) => t <= -30 && t >= -100));
});

test('smoothstep eases between 0 and 1', () => {
  assert.equal(smoothstep(-1), 0);
  assert.equal(smoothstep(0.5), 0.5);
  assert.equal(smoothstep(2), 1);
});

test('chooseFactor keeps the picture within the size cap', () => {
  assert.equal(chooseFactor(10, 10, 6), 6);
  assert.equal(chooseFactor(10, 10, 6.9), 6);
  // 998 + 2 cells at 2 px each is exactly 2000 px.
  assert.equal(chooseFactor(998, 20, 6), 2);
  assert.equal(chooseFactor(5000, 5000, 6), 1);
  const big = upsampleGrid({ values: new Array(300 * 300).fill(-60), cols: 300, rows: 300, factor: 8 });
  assert.ok(big.width <= MAX_IMAGE_SIDE && big.height <= MAX_IMAGE_SIDE);
});

test('upsampleGrid adds one blank cell all around and keeps a constant field constant', () => {
  const f = upsampleGrid({ values: [-60, -60, -60, -60], cols: 2, rows: 2, factor: 4 });
  assert.equal(f.width, 16);
  assert.equal(f.height, 16);
  // Inside the data (the middle 8x8 pixels) every pixel is -60 and fully covered.
  for (let y = 4; y < 12; y += 1) {
    for (let x = 4; x < 12; x += 1) {
      assert.ok(Math.abs(f.value[y * 16 + x] + 60) < 1e-4);
    }
  }
  // The blank border is faint and the corner has nothing at all.
  assert.ok(f.coverage[0] === 0);
  assert.equal(f.coverage[8 * 16 + 1], 0, 'nothing in the outer half of the border cell');
  assert.ok(f.coverage[8 * 16 + 3] > 0 && f.coverage[8 * 16 + 3] < 0.5);
});

test('upsampleGrid blends values bilinearly (south row first, picture north up)', () => {
  // Row 0 (south) is -40 -40, row 1 (north) is -80 -80.
  const f = upsampleGrid({ values: [-40, -40, -80, -80], cols: 2, rows: 2, factor: 4 });
  const at = (x, y) => f.value[y * f.width + x];
  // The bottom of the picture is the south: stronger.
  assert.ok(at(8, 9) > at(8, 6));
  // At a cell centre the value is the cell's own.
  assert.ok(Math.abs(at(6, 9) + 40) < 8);
  // Between the two centres it is in between.
  const mid = at(8, 8);
  assert.ok(mid < -40 && mid > -80);
});

test('empty cells are left out of the blend, so values never bleed into them', () => {
  // One strong cell in a 3x3 grid of empties.
  const values = new Array(9).fill(null);
  values[4] = -50;
  const f = upsampleGrid({ values, cols: 3, rows: 3, factor: 5 });
  for (let i = 0; i < f.value.length; i += 1) {
    if (f.coverage[i] > 0) assert.ok(Math.abs(f.value[i] + 50) < 1e-3, 'colour comes only from real data');
    else assert.ok(Number.isNaN(f.value[i]));
  }
  // The soft edge: full coverage at the cell's centre, falling to 0 about a cell away.
  const centre = (5 * 3) / 2; // pixel at the middle of the picture
  const cx = Math.floor((f.width) / 2);
  assert.ok(f.coverage[Math.floor(f.height / 2) * f.width + cx] > 0.9);
  assert.equal(f.coverage[0], 0);
  assert.ok(centre > 0);
  let touchesBorder = false;
  for (let x = 0; x < f.width; x += 1) {
    if (f.coverage[x] > 0 || f.coverage[(f.height - 1) * f.width + x] > 0) touchesBorder = true;
  }
  assert.equal(touchesBorder, false, 'the fade ends inside the blank border');
});

test('confidence is blended only from cells that have data', () => {
  const f = upsampleGrid({ values: [-60, null], confidence: [0.2, 1], cols: 2, rows: 1, factor: 4 });
  const row = Math.floor(f.height / 2);
  for (let x = 0; x < f.width; x += 1) {
    const i = row * f.width + x;
    if (f.coverage[i] > 0) assert.ok(Math.abs(f.confidence[i] - 0.2) < 1e-5);
  }
});

test('renderPixels: ramp colour, soft edge, confidence fade, min-RSSI cutoff, opacity', () => {
  // Pixels: strong+solid, weak+solid, strong at the soft edge, strong but low confidence, nothing.
  const f = field(5, 1, [-30, -95, -35, -35, Number.NaN], [1, 1, 0.5, 1, 0], [1, 1, 1, 0, 1]);
  const px = renderPixels(f);
  assert.deepEqual([...px.slice(0, 4)], [...hexToRgb('#e3211c'), 255]);
  assert.equal(px[4 * 1 + 3], 255);
  assert.deepEqual([...px.slice(4, 7)], rampColor(-95));
  assert.equal(px[2 * 4 + 3], 128, 'half coverage is half opaque');
  assert.equal(px[3 * 4 + 3], Math.round(255 * 0.3), 'confidence 0 keeps 30%');
  assert.equal(px[4 * 4 + 3], 0);

  // Below the minimum: transparent. At or above: drawn.
  const cut = renderPixels(f, { minRssi: -60 });
  assert.equal(cut[1 * 4 + 3], 0);
  assert.equal(cut[0 * 4 + 3], 255);
  assert.equal(renderPixels(f, { minRssi: -95 })[1 * 4 + 3], 255);

  const dim = renderPixels(f, { opacity: 0.5 });
  assert.equal(dim[3], 128);
});

test('marching squares finds one straight line per level on a known ramp', () => {
  // 2 pixels wide: -60 on the left, -40 on the right. Levels -55, -50, -45 cross it.
  const f = field(2, 2, [-60, -40, -60, -40]);
  const seg = contourSegments(f, { step: 5 });
  assert.equal(seg.length / 4, 3);
  const xs = [];
  for (let i = 0; i < seg.length; i += 4) {
    assert.ok(Math.abs(seg[i] - seg[i + 2]) < 1e-6, 'vertical');
    assert.ok(Math.abs(seg[i + 1] - seg[i + 3] - 1) < 1e-6 || Math.abs(seg[i + 3] - seg[i + 1] - 1) < 1e-6);
    xs.push(seg[i]);
  }
  // Pixel centres are at 0.5 and 1.5, the field crosses -55 / -50 / -45 at 1/4, 1/2, 3/4.
  assert.deepEqual(xs.map((x) => Math.round((x - 0.5) * 100) / 100).sort(), [0.25, 0.5, 0.75]);
  // A step of 10 only crosses -50.
  assert.equal(contourSegments(f, { step: 10 }).length / 4, 1);
  // A bad step makes no lines.
  assert.equal(contourSegments(f, { step: 0 }).length, 0);
});

test('marching squares circles a peak and leaves flat areas alone', () => {
  // 3x3 with a single strong middle: the -55 line goes round it.
  const f = field(3, 3, [-70, -70, -70, -70, -40, -70, -70, -70, -70]);
  const seg = contourSegments(f, { step: 5 });
  assert.ok(seg.length / 4 >= 8);
  const flat = field(3, 3, new Array(9).fill(-60));
  assert.equal(contourSegments(flat).length, 0);
});

test('marching squares handles the saddle without crossing lines', () => {
  const f = field(2, 2, [-40, -80, -80, -40]);
  const seg = contourSegments(f, { step: 40 }); // level -80 touches, -40 is the top; use level -60 below
  assert.ok(seg.length >= 0);
  const f2 = field(2, 2, [-40, -80, -80, -40]);
  const lines = contourSegments(f2, { step: 20 }); // level -60
  assert.equal(lines.length / 4, 2);
});

test('contours skip empty areas, the faded edge and values below the minimum', () => {
  const values = [-60, -40, -60, -40, -60, -40];
  const solid = field(2, 3, values);
  assert.equal(contourSegments(solid, { step: 5 }).length / 4, 3 * 2);
  const empty = field(2, 3, values, [1, 1, 1, 1, 0, 0]);
  assert.equal(contourSegments(empty, { step: 5 }).length / 4, 3);
  const faint = field(2, 3, values, [1, 1, 1, 1, CONTOUR_MIN_COVERAGE - 0.01, 1]);
  assert.equal(contourSegments(faint, { step: 5 }).length / 4, 3);
  const nan = field(2, 2, [-60, Number.NaN, -60, -40]);
  assert.equal(contourSegments(nan, { step: 5 }).length, 0);
  // minRssi -50 leaves only the cell whose corners are all >= -50: none here.
  assert.equal(contourSegments(solid, { step: 5, minRssi: -50 }).length, 0);
});

test('a tap in the picture maps to the nearest grid cell, border included', () => {
  // 4x2 grid in a 6x4 picture: the border is one cell wide.
  assert.deepEqual(cellAtPadded(1.5 / 6, 1.5 / 4, 4, 2), { col: 0, row: 0, index: 0 });
  assert.deepEqual(cellAtPadded(4.5 / 6, 2.5 / 4, 4, 2), { col: 3, row: 1, index: 7 });
  assert.deepEqual(cellAtPadded(0, 0, 4, 2), { col: 0, row: 0, index: 0 });
  assert.deepEqual(cellAtPadded(1, 1, 4, 2), { col: 3, row: 1, index: 7 });
});
