// Pure helpers for the 3D coverage page: no DOM, no Three.js, so they can be
// tested with plain Node (see tests/js/levels.test.mjs).

export const EARTH_RADIUS_M = 6371008.8;

// Colors that stay apart for the common kinds of color blindness. The legend and
// the tap info always add the level name as text, so color is never the only cue.
export const LEVEL_COLORS = Object.freeze({
  good: '#1a9850',
  fair: '#f2a900',
  dead: '#d73027',
});

export const LEVEL_NAMES = Object.freeze({
  good: 'Good',
  fair: 'Fair',
  dead: 'Dead zone',
});

// Floors are stacked at level x height. Real floor heights (about 3 m) are small
// next to a floor's width, so the gap is stretched to keep the layers readable.
export const VERTICAL_SCALE = 3;

/** good at or above goodDbm, dead below deadDbm, fair in between. */
export function levelFor(rssi, goodDbm, deadDbm) {
  if (rssi >= goodDbm) return 'good';
  if (rssi < deadDbm) return 'dead';
  return 'fair';
}

/** Text for the legend, built from the thresholds the API returned. */
export function legendEntries(thresholds) {
  const good = thresholds.good_dbm;
  const dead = thresholds.dead_dbm;
  return [
    { level: 'good', color: LEVEL_COLORS.good, text: `Good: ${good} dBm or stronger` },
    { level: 'fair', color: LEVEL_COLORS.fair, text: `Fair: ${dead} to ${good} dBm` },
    { level: 'dead', color: LEVEL_COLORS.dead, text: `Dead zone: weaker than ${dead} dBm` },
  ];
}

/** Level of every cell (null where the grid has no data). */
export function cellLevels(values, thresholds) {
  return values.map((value) =>
    value === null || value === undefined
      ? null
      : levelFor(value, thresholds.good_dbm, thresholds.dead_dbm),
  );
}

export function countLevels(levels) {
  const counts = { good: 0, fair: 0, dead: 0 };
  for (const level of levels) {
    if (level) counts[level] += 1;
  }
  return counts;
}

/**
 * The smallest block of cells that holds data, as { col0, col1, row0, row1 }
 * (inclusive), or null when the grid has no data at all.
 */
export function dataExtent(values, cols) {
  let col0 = Infinity;
  let col1 = -1;
  let row0 = Infinity;
  let row1 = -1;
  values.forEach((value, index) => {
    if (value === null || value === undefined) return;
    const col = index % cols;
    const row = Math.floor(index / cols);
    col0 = Math.min(col0, col);
    col1 = Math.max(col1, col);
    row0 = Math.min(row0, row);
    row1 = Math.max(row1, row);
  });
  return col1 < 0 ? null : { col0, col1, row0, row1 };
}

/** '#rrggbb' to [r, g, b] (0-255). */
export function hexToRgb(hex) {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

/** RGBA bytes for a texture, one pixel per cell, row 0 = south row. */
export function cellPixels(levels, alpha = 217) {
  const out = new Uint8Array(levels.length * 4);
  levels.forEach((level, i) => {
    if (!level) return; // stays fully transparent
    const [r, g, b] = hexToRgb(LEVEL_COLORS[level]);
    out.set([r, g, b, alpha], i * 4);
  });
  return out;
}

// A cell backed by no confidence at all still keeps this share of its opacity, so
// it can be seen.
export const MIN_CONFIDENCE_SHARE = 0.3;

export const CONFIDENCE_NOTE = 'Faded = few readings';

/**
 * How sure the API is of a cell, 0 to 1. A missing value (grids processed before
 * confidence existed, or a null cell) counts as 1.
 */
export function confidenceOf(raw) {
  if (typeof raw !== 'number' || Number.isNaN(raw)) return 1;
  return Math.min(1, Math.max(0, raw));
}

/** Opacity byte for a cell: `full` at confidence 1, 30% of it at confidence 0. */
export function confidenceAlpha(confidence, full = 217) {
  const share = MIN_CONFIDENCE_SHARE + (1 - MIN_CONFIDENCE_SHARE) * confidenceOf(confidence);
  return Math.round(full * share);
}

/** CSS colour of a level colour at the lowest confidence, for the legend. */
export function fadedColor(hex) {
  const [r, g, b] = hexToRgb(hex);
  return `rgba(${r}, ${g}, ${b}, ${MIN_CONFIDENCE_SHARE})`;
}

/** Equirectangular projection around the survey origin: x east, y north (m). */
export function toLocal(lat, lng, originLat, originLng) {
  const rad = Math.PI / 180;
  return {
    x: (lng - originLng) * rad * EARTH_RADIUS_M * Math.cos(originLat * rad),
    y: (lat - originLat) * rad * EARTH_RADIUS_M,
  };
}

export function floorElevation(level, heightM, scale = VERTICAL_SCALE) {
  return level * heightM * scale;
}

/** Cell under a texture coordinate (u west to east, v south to north). */
export function cellAt(u, v, cols, rows) {
  const col = Math.min(cols - 1, Math.max(0, Math.floor(u * cols)));
  const row = Math.min(rows - 1, Math.max(0, Math.floor(v * rows)));
  return { col, row, index: row * cols + col };
}

/**
 * Whether an access point is drawn as a low-confidence placement (FR-24). Results
 * processed before v1.1 have no rating, so they count as low confidence too.
 */
export function isLowConfidence(ap) {
  return ap.low_confidence !== false;
}

/** The detail line for a tapped access point: confidence, readings and spread (FR-25). */
export function apConfidenceText(ap) {
  const count = Number(ap.reading_count) || 0;
  const readings = `${count} ${count === 1 ? 'reading' : 'readings'}`;
  const spread =
    ap.spread_m === null || ap.spread_m === undefined ? '' : ` · spread ${Number(ap.spread_m).toFixed(1)} m`;
  if (ap.confidence === null || ap.confidence === undefined) {
    return `Low confidence: ${readings} · not rated, process the survey again`;
  }
  const percent = Math.round(Number(ap.confidence) * 100);
  return isLowConfidence(ap)
    ? `Low confidence: ${readings}${spread} · ${percent}%`
    : `Confidence ${percent}%: ${readings}${spread}`;
}

export function formatDbm(value) {
  return `${Number(value).toFixed(1).replace(/\.0$/, '')} dBm`;
}

export function networkLabel(network) {
  const name = network.ssid && network.ssid.length > 0 ? network.ssid : '(hidden network)';
  return `${name} · ${network.bssid}`;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value) {
  return typeof value === 'string' && UUID_RE.test(value);
}

/**
 * Settings from the URL fragment (#survey=<id>&token=<jwt>). A fragment is never
 * sent to a server, so the token stays out of access logs. Returns null if either
 * part is missing or the survey id is not a UUID.
 */
export function parseFragment(hash) {
  const params = new URLSearchParams(hash.replace(/^#/, ''));
  const surveyId = params.get('survey');
  const token = params.get('token');
  if (!isUuid(surveyId) || !token) return null;
  return { surveyId, token };
}

/** Screens at most this wide (phones) get the legend collapsed. */
export const NARROW_MAX_PX = 600;

export const LEGEND_STORAGE_KEY = 'signalscape.legend';

/**
 * Whether the legend starts open: what the person chose earlier in this session
 * ('1' open, '0' collapsed), else open on wide screens and collapsed on narrow ones.
 */
export function legendStartsOpen(stored, widthPx) {
  if (stored === '1') return true;
  if (stored === '0') return false;
  return widthPx > NARROW_MAX_PX;
}
