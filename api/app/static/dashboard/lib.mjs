// Pure helpers for the SignalScape browser dashboard (FR-37).
//
// Nothing here touches the DOM, so the Node tests in api/tests/js can run it.
// Positions are kept in local metres (east, north) from one scene origin, so a
// cell is a true square and the scale bar is exact.

export const EARTH_RADIUS_M = 6371008.8;
export const DEFAULT_THRESHOLDS = Object.freeze({ good_dbm: -67, dead_dbm: -80 });

// The same three colours as the phone app (app/lib/theme.dart). A level is
// never shown by colour alone: it always has a name, and dead cells are hatched.
export const LEVELS = Object.freeze({
  good: { label: 'Good', color: '#22C55E' },
  fair: { label: 'Weak', color: '#FBBF24' },
  dead: { label: 'Dead', color: '#FB7185' },
});

const MINUS = '−';

// --- geometry --------------------------------------------------------------

export function toGeo(x, y, originLat, originLng) {
  const lat = originLat + (y / EARTH_RADIUS_M) * (180 / Math.PI);
  const lng =
    originLng +
    (x / (EARTH_RADIUS_M * Math.cos((originLat * Math.PI) / 180))) * (180 / Math.PI);
  return { lat, lng };
}

export function toLocal(lat, lng, origin) {
  const perDegree = (Math.PI / 180) * EARTH_RADIUS_M;
  return {
    x: (lng - origin.lng) * perDegree * Math.cos((origin.lat * Math.PI) / 180),
    y: (lat - origin.lat) * perDegree,
  };
}

export function gridBounds(grid) {
  const sw = toGeo(0, 0, grid.origin_lat, grid.origin_lng);
  const ne = toGeo(
    grid.cols * grid.cell_size_m,
    grid.rows * grid.cell_size_m,
    grid.origin_lat,
    grid.origin_lng,
  );
  return { south: sw.lat, west: sw.lng, north: ne.lat, east: ne.lng };
}

/** Smallest box around cells, pins and lines (all in local metres). */
export function boundsOf({ cells = [], pins = [], lines = [] }) {
  let x0 = Infinity;
  let y0 = Infinity;
  let x1 = -Infinity;
  let y1 = -Infinity;
  const grow = (x, y) => {
    if (x < x0) x0 = x;
    if (x > x1) x1 = x;
    if (y < y0) y0 = y;
    if (y > y1) y1 = y;
  };
  for (const cell of cells) {
    grow(cell.x0, cell.y0);
    grow(cell.x1, cell.y1);
  }
  for (const pin of pins) grow(pin.x, pin.y);
  for (const line of lines) {
    grow(line.ax, line.ay);
    grow(line.bx, line.by);
  }
  if (!Number.isFinite(x0)) return null;
  return { x0, y0, x1, y1 };
}

/** A round scale-bar length (1, 2 or 5 times a power of ten) that fits maxPx. */
export function niceScale(metersPerPixel, maxPx = 120) {
  if (!(metersPerPixel > 0)) return { meters: 0, px: 0, label: '' };
  const limit = metersPerPixel * maxPx;
  const power = 10 ** Math.floor(Math.log10(limit));
  let meters = power;
  for (const step of [5, 2, 1]) {
    if (step * power <= limit) {
      meters = step * power;
      break;
    }
  }
  const label = meters >= 1000 ? `${meters / 1000} km` : `${meters} m`;
  return { meters, px: meters / metersPerPixel, label };
}

// --- signal levels ---------------------------------------------------------

export function levelOf(rssi, thresholds = DEFAULT_THRESHOLDS) {
  if (rssi == null || Number.isNaN(rssi)) return null;
  if (rssi >= thresholds.good_dbm) return 'good';
  if (rssi >= thresholds.dead_dbm) return 'fair';
  return 'dead';
}

export function levelColor(rssi, good, dead) {
  const level = levelOf(rssi, { good_dbm: good, dead_dbm: dead });
  return level ? LEVELS[level].color : null;
}

/**
 * Colour of one cell, or null when it is hidden. "Good coverage" shows good
 * cells; "Weak and dead zones" shows the other two.
 */
export function cellColor(rssi, thresholds, showGood, showZones) {
  const level = levelOf(rssi, thresholds);
  if (!level) return null;
  if (level === 'good' ? !showGood : !showZones) return null;
  return LEVELS[level].color;
}

// --- scene building --------------------------------------------------------

/** Cells of one stored or consolidated grid. */
export function cellsFromGrid(grid, thresholds, origin, floor) {
  const base = toLocal(grid.origin_lat, grid.origin_lng, origin);
  const size = grid.cell_size_m;
  const cells = [];
  const values = grid.values || [];
  for (let i = 0; i < values.length; i += 1) {
    const rssi = values[i];
    const level = levelOf(rssi, thresholds);
    if (!level) continue;
    const row = Math.floor(i / grid.cols);
    const col = i % grid.cols;
    cells.push({
      x0: base.x + col * size,
      y0: base.y + row * size,
      x1: base.x + (col + 1) * size,
      y1: base.y + (row + 1) * size,
      rssi,
      level,
      floor,
    });
  }
  return cells;
}

/** Cells and access-point pins from a survey's GeoJSON. */
export function sceneFromFeatures(features, thresholds, origin) {
  const cells = [];
  const pins = [];
  for (const feature of features || []) {
    const props = feature.properties || {};
    const geometry = feature.geometry;
    if (!geometry || !geometry.coordinates) continue;
    if (props.kind === 'coverage') {
      const ring = geometry.coordinates[0] || [];
      if (!ring.length) continue;
      let x0 = Infinity;
      let y0 = Infinity;
      let x1 = -Infinity;
      let y1 = -Infinity;
      for (const [lng, lat] of ring) {
        const p = toLocal(lat, lng, origin);
        x0 = Math.min(x0, p.x);
        x1 = Math.max(x1, p.x);
        y0 = Math.min(y0, p.y);
        y1 = Math.max(y1, p.y);
      }
      const level = levelOf(props.rssi_dbm, thresholds);
      if (!level) continue;
      cells.push({ x0, y0, x1, y1, rssi: props.rssi_dbm, level, floor: props.floor_level });
    } else if (props.kind === 'access_point') {
      const [lng, lat] = geometry.coordinates;
      const p = toLocal(lat, lng, origin);
      pins.push({
        x: p.x,
        y: p.y,
        floor: props.floor_level,
        label: props.ssid || props.bssid || 'Router',
        bssid: props.bssid,
        rssi: props.rssi_dbm,
        low: Boolean(props.low_confidence),
        confidence: props.confidence,
        kind: 'ap',
      });
    }
  }
  return { cells, pins };
}

/** First coordinate of the first coverage cell or access point, as an origin. */
export function originOfFeatures(features) {
  for (const feature of features || []) {
    const geometry = feature.geometry;
    if (!geometry || !geometry.coordinates) continue;
    const point =
      feature.properties?.kind === 'coverage'
        ? (geometry.coordinates[0] || [])[0]
        : geometry.coordinates;
    if (point && Number.isFinite(point[0]) && Number.isFinite(point[1])) {
      return { lat: point[1], lng: point[0] };
    }
  }
  return null;
}

/** The topmost visible cell under a point, or null. */
export function findCell(cells, x, y, isVisible = () => true) {
  for (let i = cells.length - 1; i >= 0; i -= 1) {
    const cell = cells[i];
    if (x >= cell.x0 && x < cell.x1 && y >= cell.y0 && y < cell.y1 && isVisible(cell)) {
      return cell;
    }
  }
  return null;
}

// --- figures ---------------------------------------------------------------

/** Area-weighted share of good, weak and dead ground across floors. */
export function aggregateFloors(floors) {
  let area = 0;
  let good = 0;
  let fair = 0;
  let dead = 0;
  let readings = 0;
  let routers = 0;
  for (const floor of floors || []) {
    const a = floor.area_covered_m2 || 0;
    area += a;
    good += (a * (floor.good_pct || 0)) / 100;
    fair += (a * (floor.fair_pct || 0)) / 100;
    dead += (a * (floor.dead_pct || 0)) / 100;
    readings += floor.raw_reading_count || 0;
    routers += floor.access_point_count || 0;
  }
  const pct = (part) => (area > 0 ? (part / area) * 100 : 0);
  return {
    area,
    readings,
    routers,
    hasData: area > 0,
    good: pct(good),
    fair: pct(fair),
    dead: pct(dead),
  };
}

/** Floors as chips, one per level, lowest first. Merges same levels. */
export function floorChoices(floors) {
  const byLevel = new Map();
  for (const floor of floors || []) {
    const level = floor.floor_level;
    const entry = byLevel.get(level) || { level, label: floor.floor_label, area: 0 };
    entry.area += floor.area_covered_m2 || 0;
    byLevel.set(level, entry);
  }
  return [...byLevel.values()].sort((a, b) => a.level - b.level);
}

/** The floor most worth showing first: the one with the most surveyed ground. */
export function defaultFloor(choices) {
  if (!choices.length) return null;
  return choices.reduce((best, item) => (item.area > best.area ? item : best)).level;
}

// --- formatting ------------------------------------------------------------

export function formatDbm(value) {
  if (value == null || Number.isNaN(value)) return '–';
  const rounded = Math.round(value);
  return `${rounded < 0 ? MINUS : ''}${Math.abs(rounded)} dBm`;
}

export function formatPct(value) {
  if (value == null || Number.isNaN(value)) return '–';
  return `${value >= 99.95 || value === 0 ? Math.round(value) : value.toFixed(1)}%`;
}

export function formatArea(m2) {
  if (m2 == null || Number.isNaN(m2)) return '–';
  return `${Math.round(m2).toLocaleString('en-US')} m²`;
}

export function formatMeters(m) {
  if (m == null || Number.isNaN(m)) return '–';
  return m >= 10 ? `${Math.round(m)} m` : `${m.toFixed(1)} m`;
}

export function formatDate(iso) {
  if (!iso) return '';
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

export function formatDateTime(iso) {
  if (!iso) return '';
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  const day = formatDate(iso);
  const time = date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  return `${day}, ${time}`;
}

// --- choosing data ---------------------------------------------------------

export const isProcessed = (survey) => survey?.status === 'processed';

export function buildingsForSite(buildings, site) {
  if (!site) return buildings;
  const ids = new Set(site.building_ids || []);
  return buildings.filter((building) => ids.has(building.id));
}

/** Surveys under the current site and building filters, newest first. */
export function surveysForScope(surveys, { site, buildingId } = {}) {
  let list = surveys;
  if (site) {
    const ids = new Set(site.building_ids || []);
    list = list.filter((survey) => ids.has(survey.building_id));
  }
  if (buildingId) list = list.filter((survey) => survey.building_id === buildingId);
  return [...list].sort((a, b) => String(b.started_at).localeCompare(String(a.started_at)));
}

// --- address bar state -----------------------------------------------------
// A selection lives in the URL fragment so it can be bookmarked, shared and
// reached with the Back button. The fragment never holds the token.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const VIEWS = ['coverage', 'routers', '3d'];
export const MODES = ['survey', 'campus'];

export function parseHash(hash) {
  const params = new URLSearchParams(String(hash || '').replace(/^#/, ''));
  const out = {};
  for (const key of ['site', 'building', 'survey']) {
    const value = params.get(key);
    if (value && UUID.test(value)) out[key] = value.toLowerCase();
  }
  const view = params.get('view');
  if (VIEWS.includes(view)) out.view = view;
  const mode = params.get('mode');
  if (MODES.includes(mode)) out.mode = mode;
  return out;
}

export function buildHash(state) {
  const params = new URLSearchParams();
  for (const key of ['mode', 'site', 'building', 'survey', 'view']) {
    if (state[key]) params.set(key, state[key]);
  }
  const text = params.toString();
  return text ? `#${text}` : '';
}

// --- Markdown (the report) -------------------------------------------------
// A small reader for the Markdown the API writes: headings, paragraphs, lists
// and pipe tables, with bold, italic and code inside text. It returns data;
// the page turns that into elements with textContent, never as HTML.

const TABLE_RULE = /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/;

function splitRow(line) {
  let text = line.trim();
  if (text.startsWith('|')) text = text.slice(1);
  if (text.endsWith('|')) text = text.slice(0, -1);
  return text.split('|').map((cell) => cell.trim());
}

export function parseInline(text) {
  const parts = [];
  const pattern = /(\*\*[^*]+\*\*|`[^`]+`|\*[^*\s][^*]*\*|_[^_\s][^_]*_)/g;
  let last = 0;
  for (const match of text.matchAll(pattern)) {
    if (match.index > last) parts.push({ type: 'text', text: text.slice(last, match.index) });
    const token = match[0];
    if (token.startsWith('**')) parts.push({ type: 'strong', text: token.slice(2, -2) });
    else if (token.startsWith('`')) parts.push({ type: 'code', text: token.slice(1, -1) });
    else parts.push({ type: 'em', text: token.slice(1, -1) });
    last = match.index + token.length;
  }
  if (last < text.length) parts.push({ type: 'text', text: text.slice(last) });
  return parts;
}

export function parseMarkdown(source) {
  const lines = String(source || '').replace(/\r\n?/g, '\n').split('\n');
  const blocks = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) {
      i += 1;
      continue;
    }
    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      blocks.push({ type: 'heading', level: heading[1].length, text: heading[2].trim() });
      i += 1;
      continue;
    }
    if (/^\s*([-*_])\1{2,}\s*$/.test(line)) {
      blocks.push({ type: 'rule' });
      i += 1;
      continue;
    }
    if (line.includes('|') && i + 1 < lines.length && TABLE_RULE.test(lines[i + 1])) {
      const header = splitRow(line);
      const align = splitRow(lines[i + 1]).map((cell) =>
        cell.endsWith(':') ? (cell.startsWith(':') ? 'center' : 'right') : 'left',
      );
      const rows = [];
      i += 2;
      while (i < lines.length && lines[i].includes('|') && lines[i].trim()) {
        rows.push(splitRow(lines[i]));
        i += 1;
      }
      blocks.push({ type: 'table', header, align, rows });
      continue;
    }
    const bullet = /^\s*[-*+]\s+/;
    const numbered = /^\s*\d+[.)]\s+/;
    if (bullet.test(line) || numbered.test(line)) {
      const ordered = numbered.test(line);
      const marker = ordered ? numbered : bullet;
      const items = [];
      while (i < lines.length && marker.test(lines[i])) {
        items.push(lines[i].replace(marker, '').trim());
        i += 1;
      }
      blocks.push({ type: 'list', ordered, items });
      continue;
    }
    const paragraph = [line.trim()];
    i += 1;
    while (
      i < lines.length &&
      lines[i].trim() &&
      !/^(#{1,6})\s/.test(lines[i]) &&
      !/^\s*([-*+]|\d+[.)])\s+/.test(lines[i])
    ) {
      paragraph.push(lines[i].trim());
      i += 1;
    }
    blocks.push({ type: 'paragraph', text: paragraph.join(' ') });
  }
  return blocks;
}
