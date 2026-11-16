// Smooth heatmap maths for the 3D coverage page: no DOM, no Three.js, so it can be
// tested with plain Node (see tests/js/heat.test.mjs). The Flutter app has the same
// maths in app/lib/core/heatmap.dart; keep the ramp stops and the rules below in step.
//
// The API still sends a plain grid (1 m cells, null = no data, confidence 0..1).
// This module turns it into a continuous picture:
//   1. upsampleGrid: bilinear upsampling that never mixes in empty cells.
//   2. renderPixels: dBm -> rainbow ramp, with soft edges and the confidence fade.
//   3. contourSegments: marching squares, a thin line every few dB.

import { MIN_CONFIDENCE_SHARE, confidenceOf, hexToRgb } from './levels.mjs';

/**
 * The colour ramp, strong to weak, like Acrylic Wi-Fi Heatmaps. Colours are
 * interpolated linearly in RGB between these stops, and clamped outside them.
 * -67 dBm (green) is also the default "good" threshold.
 */
export const RAMP_STOPS = Object.freeze([
  { dbm: -30, color: '#e3211c' }, // red: very strong
  { dbm: -45, color: '#f7861e' }, // orange
  { dbm: -57, color: '#fbe51a' }, // yellow
  { dbm: -67, color: '#38b54a' }, // green
  { dbm: -78, color: '#18c8dc' }, // cyan
  { dbm: -90, color: '#2b5fd9' }, // blue
  { dbm: -100, color: '#1b2166' }, // dark blue: nothing usable
]);

export const RAMP_STRONG_DBM = RAMP_STOPS[0].dbm;
export const RAMP_WEAK_DBM = RAMP_STOPS[RAMP_STOPS.length - 1].dbm;

/** Ticks on the legend bar. */
export const LEGEND_TICKS = Object.freeze([-30, -45, -60, -75, -90, -100]);

export const DEFAULT_CONTOUR_STEP_DB = 5;
export const DEFAULT_UPSAMPLE = 6;
export const MAX_IMAGE_SIDE = 2048;
// The picture has one blank cell all around the grid, so the edge can fade out.
export const PAD_CELLS = 1;
// Contour lines are only drawn where the picture is at least this solid.
export const CONTOUR_MIN_COVERAGE = 0.5;

const STOP_RGB = RAMP_STOPS.map((stop) => hexToRgb(stop.color));

/** [r, g, b] (0-255) of a signal strength in dBm, on the ramp. */
export function rampColor(dbm) {
  if (!(dbm < RAMP_STRONG_DBM)) return STOP_RGB[0].slice();
  if (dbm <= RAMP_WEAK_DBM) return STOP_RGB[STOP_RGB.length - 1].slice();
  for (let i = 0; i < RAMP_STOPS.length - 1; i += 1) {
    const hi = RAMP_STOPS[i].dbm;
    const lo = RAMP_STOPS[i + 1].dbm;
    if (dbm <= hi && dbm >= lo) {
      const t = (hi - dbm) / (hi - lo);
      return STOP_RGB[i].map((c, k) => Math.round(c + (STOP_RGB[i + 1][k] - c) * t));
    }
  }
  return STOP_RGB[STOP_RGB.length - 1].slice();
}

/** Position of a dBm value along the legend bar: 0 = strongest end, 1 = weakest. */
export function rampFraction(dbm) {
  const t = (RAMP_STRONG_DBM - dbm) / (RAMP_STRONG_DBM - RAMP_WEAK_DBM);
  return Math.min(1, Math.max(0, t));
}

export function smoothstep(x) {
  const t = Math.min(1, Math.max(0, x));
  return t * t * (3 - 2 * t);
}

/** The upsampling factor actually used: as asked, but the picture stays within maxSide. */
export function chooseFactor(cols, rows, requested = DEFAULT_UPSAMPLE, maxSide = MAX_IMAGE_SIDE) {
  const longest = Math.max(cols, rows) + 2 * PAD_CELLS;
  return Math.max(1, Math.min(Math.floor(requested), Math.floor(maxSide / longest)));
}

function isNumber(x) {
  return typeof x === 'number' && !Number.isNaN(x);
}

/**
 * Bilinear upsampling of a grid (values row-major, row 0 = south row, null = no
 * data). The result is a picture in image order (row 0 = north) that covers the grid
 * plus one blank cell on every side:
 *   width  = (cols + 2) * factor, height = (rows + 2) * factor
 *   value[i]     dBm at the pixel, NaN where nothing is near
 *   coverage[i]  0..1, the share of the four nearest cell centres that have data;
 *                it falls to 0 about one cell away from the data
 *   confidence[i] 0..1, from the API confidence of the cells that count
 * Empty cells are left out of the blend (weights are renormalised), so colours never
 * bleed into empty areas and the value never drifts towards zero.
 */
export function upsampleGrid({ values, confidence = null, cols, rows, factor = DEFAULT_UPSAMPLE, maxSide = MAX_IMAGE_SIDE }) {
  const f = chooseFactor(cols, rows, factor, maxSide);
  const width = (cols + 2 * PAD_CELLS) * f;
  const height = (rows + 2 * PAD_CELLS) * f;
  const value = new Float32Array(width * height).fill(Number.NaN);
  const coverage = new Float32Array(width * height);
  const conf = new Float32Array(width * height);
  const sampleCols = new Int32Array(2);
  const weightsX = new Float64Array(2);
  for (let py = 0; py < height; py += 1) {
    const ys = (height - py - 0.5) / f - 0.5; // padded row index, south = 0
    const y0 = Math.floor(ys);
    const ty = ys - y0;
    for (let px = 0; px < width; px += 1) {
      const xs = (px + 0.5) / f - 0.5;
      const x0 = Math.floor(xs);
      const tx = xs - x0;
      sampleCols[0] = x0 - PAD_CELLS;
      sampleCols[1] = x0 + 1 - PAD_CELLS;
      weightsX[0] = 1 - tx;
      weightsX[1] = tx;
      let wsum = 0;
      let vsum = 0;
      let csum = 0;
      for (let dy = 0; dy < 2; dy += 1) {
        const row = y0 + dy - PAD_CELLS;
        if (row < 0 || row >= rows) continue;
        const wy = dy === 0 ? 1 - ty : ty;
        for (let dx = 0; dx < 2; dx += 1) {
          const col = sampleCols[dx];
          if (col < 0 || col >= cols) continue;
          const index = row * cols + col;
          const v = values[index];
          if (!isNumber(v)) continue;
          const w = wy * weightsX[dx];
          wsum += w;
          vsum += w * v;
          csum += w * confidenceOf(confidence ? confidence[index] : 1);
        }
      }
      if (wsum > 1e-6) {
        const i = py * width + px;
        value[i] = vsum / wsum;
        coverage[i] = Math.min(1, wsum);
        conf[i] = csum / wsum;
      }
    }
  }
  return { width, height, factor: f, pad: PAD_CELLS, cols, rows, value, coverage, confidence: conf };
}

/**
 * RGBA bytes of the picture. A pixel is transparent where there is no data or where
 * the value is below minRssi. Elsewhere its colour is the ramp colour of the value,
 * and its opacity is: edge softness (coverage, smoothed) x confidence fade x opacity.
 */
export function renderPixels(field, { minRssi = RAMP_WEAK_DBM, opacity = 1 } = {}) {
  const out = new Uint8ClampedArray(field.width * field.height * 4);
  const total = field.width * field.height;
  for (let i = 0; i < total; i += 1) {
    const v = field.value[i];
    const cover = field.coverage[i];
    if (cover <= 0 || Number.isNaN(v) || v < minRssi) continue;
    const share = MIN_CONFIDENCE_SHARE + (1 - MIN_CONFIDENCE_SHARE) * field.confidence[i];
    const alpha = smoothstep(cover) * share * opacity;
    const [r, g, b] = rampColor(v);
    out[i * 4] = r;
    out[i * 4 + 1] = g;
    out[i * 4 + 2] = b;
    out[i * 4 + 3] = Math.round(255 * Math.min(1, Math.max(0, alpha)));
  }
  return out;
}

// Marching squares. A cell has corners TL, TR, BR, BL (bits 0..3, set when the corner
// is at or above the level) and edges top=0, right=1, bottom=2, left=3. Each case
// lists the edge pairs a line joins.
const SEGMENTS = [
  [], [[3, 0]], [[0, 1]], [[3, 1]], [[1, 2]], null, [[0, 2]], [[3, 2]],
  [[2, 3]], [[0, 2]], null, [[1, 2]], [[3, 1]], [[0, 1]], [[3, 0]], [],
];

/**
 * Contour lines of the picture at every `step` dB (multiples of step, so -50, -55 ...).
 * Returns a flat Float32Array [x0, y0, x1, y1, ...] in pixel units, y down, where
 * pixel (i, j) has its centre at (i + 0.5, j + 0.5). Lines are only made between
 * pixels that have data, are at least CONTOUR_MIN_COVERAGE solid and are not below
 * minRssi, so there are none in the fade-out or in empty areas.
 */
export function contourSegments(field, { step = DEFAULT_CONTOUR_STEP_DB, minRssi = RAMP_WEAK_DBM } = {}) {
  if (!(step > 0)) return new Float32Array(0);
  const { width, height, value, coverage } = field;
  const ok = (i) => coverage[i] >= CONTOUR_MIN_COVERAGE && !Number.isNaN(value[i]) && value[i] >= minRssi;
  const out = [];
  const point = (edge, x, y, level, vtl, vtr, vbr, vbl) => {
    // Position along the edge where the field crosses the level.
    switch (edge) {
      case 0: return [x + 0.5 + (level - vtl) / (vtr - vtl), y + 0.5];
      case 1: return [x + 1.5, y + 0.5 + (level - vtr) / (vbr - vtr)];
      case 2: return [x + 0.5 + (level - vbl) / (vbr - vbl), y + 1.5];
      default: return [x + 0.5, y + 0.5 + (level - vtl) / (vbl - vtl)];
    }
  };
  for (let y = 0; y < height - 1; y += 1) {
    for (let x = 0; x < width - 1; x += 1) {
      const itl = y * width + x;
      const ibl = itl + width;
      if (!(ok(itl) && ok(itl + 1) && ok(ibl) && ok(ibl + 1))) continue;
      const vtl = value[itl];
      const vtr = value[itl + 1];
      const vbl = value[ibl];
      const vbr = value[ibl + 1];
      const lo = Math.min(vtl, vtr, vbl, vbr);
      const hi = Math.max(vtl, vtr, vbl, vbr);
      for (let level = Math.ceil(lo / step) * step; level < hi; level += step) {
        if (level <= lo) continue; // a level at the very bottom or top of a cell has no line
        const index = (vtl >= level ? 1 : 0) | (vtr >= level ? 2 : 0) | (vbr >= level ? 4 : 0) | (vbl >= level ? 8 : 0);
        let pairs = SEGMENTS[index];
        if (pairs === null) {
          const centreHigh = (vtl + vtr + vbr + vbl) / 4 >= level;
          if (index === 5) pairs = centreHigh ? [[0, 1], [3, 2]] : [[3, 0], [1, 2]];
          else pairs = centreHigh ? [[3, 0], [1, 2]] : [[0, 1], [3, 2]];
        }
        for (const [a, b] of pairs) {
          const p = point(a, x, y, level, vtl, vtr, vbr, vbl);
          const q = point(b, x, y, level, vtl, vtr, vbr, vbl);
          out.push(p[0], p[1], q[0], q[1]);
        }
      }
    }
  }
  return Float32Array.from(out);
}

/**
 * The grid cell under a texture coordinate of the picture (u west to east, v south
 * to north, both 0..1 over the padded picture). Points in the blank border give the
 * nearest cell, so a tap just outside the data still reports the nearest value.
 */
export function cellAtPadded(u, v, cols, rows) {
  const col = Math.min(cols - 1, Math.max(0, Math.floor(u * (cols + 2 * PAD_CELLS)) - PAD_CELLS));
  const row = Math.min(rows - 1, Math.max(0, Math.floor(v * (rows + 2 * PAD_CELLS)) - PAD_CELLS));
  return { col, row, index: row * cols + col };
}

/** Text for a slider: "-75 dBm". */
export function dbmText(value) {
  return `${Math.round(value)} dBm`;
}
