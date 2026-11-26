// SignalScape browser dashboard (FR-37).
//
// Signed-in Admin opens consolidated campus maps, the dead and weak layer,
// router coverage and the analysis report in a browser. Every request carries
// the JWT from browser sign-in; the page itself holds no survey data.
// All text from the API is written with textContent, never as HTML.

const TOKEN_KEY = 'signalscape.dashboard.token';
const EARTH_RADIUS_M = 6371008.8;
const MAX_PER_PAGE = 100;

const $ = (id) => document.getElementById(id);

export function toGeo(x, y, originLat, originLng) {
  const lat = originLat + (y / EARTH_RADIUS_M) * (180 / Math.PI);
  const lng =
    originLng +
    (x / (EARTH_RADIUS_M * Math.cos((originLat * Math.PI) / 180))) *
      (180 / Math.PI);
  return { lat, lng };
}

export function levelColor(rssi, good, dead) {
  if (rssi >= good) return '#16a34a';
  if (rssi >= dead) return '#d97706';
  return '#dc2626';
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

export function cellColor(rssi, thresholds, showHeat, showZones) {
  if (rssi == null) return null;
  const level = rssi >= thresholds.good_dbm ? 'good' : rssi >= thresholds.dead_dbm ? 'fair' : 'dead';
  if (!showZones && level !== 'good') return null;
  if (!showHeat && level === 'good') return null;
  return levelColor(rssi, thresholds.good_dbm, thresholds.dead_dbm);
}

let token =
  typeof sessionStorage !== 'undefined' ? sessionStorage.getItem(TOKEN_KEY) || '' : '';
let me = null;
let sites = [];
let buildings = [];
let surveys = [];
let view = null;
let lastReport = null;

function status(message) {
  $('status').textContent = message || '';
}

async function api(path, { method = 'GET', json, form } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  let body;
  if (json !== undefined) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(json);
  } else if (form) {
    body = new URLSearchParams(form);
  }
  const response = await fetch(`/api${path}`, { method, headers, body });
  if (!response.ok) {
    let detail = `${response.status} ${response.statusText}`;
    try {
      const error = await response.json();
      if (error.detail) detail = typeof error.detail === 'string' ? error.detail : JSON.stringify(error.detail);
    } catch {
      // keep the HTTP status text
    }
    throw new Error(detail);
  }
  if (response.status === 204) return null;
  return response.json();
}

async function run(action) {
  try {
    status('Working…');
    await action();
    status('');
  } catch (error) {
    status(error instanceof Error ? error.message : String(error));
  }
}

function fill(select, items, label, value = (item) => item.id, placeholder) {
  select.replaceChildren();
  if (placeholder) select.add(new Option(placeholder, ''));
  for (const item of items) select.add(new Option(label(item), value(item)));
}

function isAdmin() {
  return me?.role === 'admin';
}

function selectedId(select) {
  return select.value || null;
}

function siteById(id) {
  return sites.find((site) => site.id === id) || null;
}

function surveysForSite(site) {
  if (!site) return surveys;
  const ids = new Set(site.building_ids || []);
  return surveys.filter((survey) => ids.has(survey.building_id));
}

function surveyLabel(survey) {
  const building = buildings.find((item) => item.id === survey.building_id);
  const name = building ? building.name : survey.building_id;
  const day = (survey.started_at || '').slice(0, 10);
  return day ? `${name} — ${day}` : name;
}

function showView(kind) {
  $('viewer').hidden = kind !== '3d';
  $('map').hidden = !(kind === 'map' || kind === 'routers');
  $('routers').hidden = kind !== 'routers';
  $('layers').hidden = kind === 'routers';
}

// --- canvas drawing --------------------------------------------------------


function fit(canvas, boundsList) {
  const south = Math.min(...boundsList.map((b) => b.south));
  const west = Math.min(...boundsList.map((b) => b.west));
  const north = Math.max(...boundsList.map((b) => b.north));
  const east = Math.max(...boundsList.map((b) => b.east));
  const width = canvas.width;
  const height = canvas.height;
  const pad = 24;
  const spanLat = Math.max(north - south, 1e-9);
  const spanLng = Math.max(east - west, 1e-9);
  const scale = Math.min(
    (width - 2 * pad) / spanLng,
    (height - 2 * pad) / spanLat,
  );
  const usedW = spanLng * scale;
  const usedH = spanLat * scale;
  const offX = (width - usedW) / 2;
  const offY = (height - usedH) / 2;
  return (lat, lng) => ({
    x: offX + (lng - west) * scale,
    y: height - offY - (lat - south) * scale,
  });
}

function draw(cells, aps) {
  const canvas = $('map');
  const ctx = canvas.getContext('2d');
  const ratio = window.devicePixelRatio || 1;
  const rect = canvas.getBoundingClientRect();
  canvas.width = Math.max(1, Math.floor(rect.width * ratio));
  canvas.height = Math.max(1, Math.floor(rect.height * ratio));
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  if (!cells.length) {
    status('No coverage cells to draw.');
    return;
  }
  const project = fit(canvas, cells.map((cell) => cell.bounds));
  ctx.globalAlpha = 0.55;
  for (const cell of cells) {
    const a = project(cell.bounds.south, cell.bounds.west);
    const b = project(cell.bounds.north, cell.bounds.east);
    ctx.fillStyle = cell.color;
    ctx.fillRect(a.x, b.y, Math.max(1, b.x - a.x), Math.max(1, a.y - b.y));
  }
  ctx.globalAlpha = 1;
  for (const ap of aps) {
    if (ap.lat == null || ap.lng == null) continue;
    const point = project(ap.lat, ap.lng);
    ctx.beginPath();
    ctx.arc(point.x, point.y, 5 * ratio, 0, 2 * Math.PI);
    ctx.fillStyle = ap.low_confidence ? '#94a3b8' : '#1d4ed8';
    ctx.fill();
    ctx.strokeStyle = '#ffffff';
    ctx.lineWidth = 1 * ratio;
    ctx.stroke();
  }
}

function gridCells(grid, thresholds) {
  const cells = [];
  const values = grid.values || [];
  for (let i = 0; i < values.length; i += 1) {
    const row = Math.floor(i / grid.cols);
    const col = i % grid.cols;
    const color = cellColor(
      values[i], thresholds, $('show-heat').checked, $('show-zones').checked,
    );
    if (!color) continue;
    const sw = toGeo(
      col * grid.cell_size_m, row * grid.cell_size_m, grid.origin_lat, grid.origin_lng,
    );
    const ne = toGeo(
      (col + 1) * grid.cell_size_m, (row + 1) * grid.cell_size_m,
      grid.origin_lat, grid.origin_lng,
    );
    cells.push({
      bounds: { south: sw.lat, west: sw.lng, north: ne.lat, east: ne.lng },
      color,
    });
  }
  return cells;
}

function featureCells(features) {
  const cells = [];
  for (const feature of features) {
    if (feature.properties?.kind !== 'coverage' || !feature.geometry?.coordinates) continue;
    const ring = feature.geometry.coordinates[0] || [];
    const lngs = ring.map((point) => point[0]);
    const lats = ring.map((point) => point[1]);
    if (!lats.length) continue;
    const thresholds = view?.thresholds || { good_dbm: -67, dead_dbm: -80 };
    const color = cellColor(
      feature.properties.rssi_dbm, thresholds, $('show-heat').checked, $('show-zones').checked,
    );
    if (!color) continue;
    cells.push({
      bounds: {
        south: Math.min(...lats), west: Math.min(...lngs),
        north: Math.max(...lats), east: Math.max(...lngs),
      },
      color,
    });
  }
  return cells;
}

// --- panels ----------------------------------------------------------------


function showReport(facts) {
  $('report').hidden = false;
  $('report-facts').replaceChildren();
  const add = (text) => {
    const p = document.createElement('p');
    p.textContent = text;
    $('report-facts').append(p);
  };
  add(`${facts.title} — ${facts.scope}`);
  add(
    `${facts.reading_count} readings, ${facts.access_point_count} routers ` +
      `(${facts.determined_access_point_count} placed, ` +
      `${facts.low_confidence_count} low confidence)`,
  );
  add(
    `Good ≥ ${facts.thresholds.good_dbm} dBm, dead < ${facts.thresholds.dead_dbm} dBm. ` +
      `Area-weighted: ${facts.good_pct.toFixed(1)}% good, ` +
      `${facts.fair_pct.toFixed(1)}% fair, ${facts.dead_pct.toFixed(1)}% dead.`,
  );
  $('report-text').textContent = '';
  $('export-report').hidden = true;
  lastReport = null;
}

function addRoute(container, title, detail) {
  const row = document.createElement('div');
  row.className = 'route';
  const strong = document.createElement('strong');
  strong.textContent = title;
  const small = document.createElement('small');
  small.textContent = detail;
  row.append(strong, small);
  container.append(row);
}

function renderRouters(data) {
  showView('routers');
  $('routers').replaceChildren();
  const heading = document.createElement('h2');
  heading.textContent = `Router coverage — ${data.router_count} routers`;
  $('routers').append(heading);
  const networks = data.extended_networks || [];
  if (!networks.length) {
    const note = document.createElement('p');
    note.className = 'note';
    note.textContent = 'No network is served by more than one router.';
    $('routers').append(note);
  }
  for (const network of networks) {
    addRoute(
      $('routers'),
      `${network.ssid} — ${network.router_count} routers`,
      network.floors
        .map(
          (floor) =>
            `${floor.floor_label}: ${floor.links.length} links, ` +
            `${floor.weak_cells} weak + ${floor.dead_cells} dead cells` +
            (floor.likely_main ? `, likely main ${floor.likely_main}` : ''),
        )
        .join(' | '),
    );
  }
  const cells = [];
  for (const network of networks) {
    for (const floor of network.floors) {
      const gaps = floor.gaps && floor.gap_area_m2 > 0 ? floor.gaps : floor.coverage;
      if (gaps) {
        cells.push(...gridCells(gaps, data.thresholds));
      }
    }
  }
  if (cells.length) {
    draw(cells, []);
  }
}

function renderConsolidation(result) {
  view = { kind: 'site', thresholds: result.thresholds, result };
  const cells = [];
  for (const grid of result.grids) {
    cells.push(...gridCells(grid, result.thresholds));
  }
  showView('map');
  draw(cells, result.access_points);
  $('legend').textContent =
    `Good ≥ ${result.thresholds.good_dbm} dBm, dead < ${result.thresholds.dead_dbm} dBm. ` +
    `${result.survey_ids.length} surveys merged.`;
  showReport(result.facts || {
    title: siteById(selectedId($('site')))?.name || 'Campus view',
    scope: 'site',
    thresholds: result.thresholds,
    reading_count: result.floors.reduce((n, f) => n + f.raw_reading_count, 0),
    access_point_count: result.access_points.length,
    determined_access_point_count: result.access_points.filter((a) => a.position_determined).length,
    low_confidence_count: result.access_points.filter((a) => a.low_confidence).length,
    good_pct: 0, fair_pct: 0, dead_pct: 0,
  });
}

// --- loading ---------------------------------------------------------------


async function loadPickers() {
  const [sitePage, buildingPage, surveyPage] = await Promise.all([
    api('/sites?page_size=' + MAX_PER_PAGE),
    api('/buildings?page_size=' + MAX_PER_PAGE),
    api('/surveys?page_size=' + MAX_PER_PAGE),
  ]);
  sites = sitePage.items;
  buildings = buildingPage.items;
  surveys = surveyPage.items;
  fill($('site'), sites, (site) => site.name, (site) => site.id, 'No site');
  fill($('building'), buildings, (building) => building.name, (building) => building.id, 'All buildings');
  fill($('survey'), surveys, (survey) => surveyLabel(survey), (survey) => survey.id, 'Choose a survey');
  $('admin-set').hidden = !isAdmin();
  refreshConsolidationList();
  refreshSiteBuildings();
}

function refreshConsolidationList() {
  const container = $('consolidation-surveys');
  container.replaceChildren();
  const choices = surveysForSite(siteById(selectedId($('site'))));
  if (!choices.length) {
    const note = document.createElement('p');
    note.className = 'note';
    note.textContent = 'No processed surveys on this site yet.';
    container.append(note);
  }
  for (const survey of choices) {
    const label = document.createElement('label');
    label.className = 'check';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.value = survey.id;
    box.checked = true;
    label.append(box, document.createTextNode(surveyLabel(survey)));
    container.append(label);
  }
}

function refreshSiteBuildings() {
  const container = $('site-buildings');
  container.replaceChildren();
  for (const building of buildings) {
    const label = document.createElement('label');
    label.className = 'check';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.value = building.id;
    label.append(box, document.createTextNode(building.name));
    container.append(label);
  }
}

async function load() {
  if (!token) {
    $('sign-in').hidden = false;
    $('workspace').hidden = true;
    $('identity').textContent = '';
    $('sign-out').hidden = true;
    return;
  }
  try {
    me = await api('/auth/me');
  } catch {
    token = '';
    sessionStorage.removeItem(TOKEN_KEY);
    await load();
    return;
  }
  $('sign-in').hidden = true;
  $('workspace').hidden = false;
  $('identity').textContent = `${me.name} (${me.role})`;
  $('sign-out').hidden = false;
  await loadPickers();
}

function selectedSurveys() {
  return [...$('consolidation-surveys').querySelectorAll('input:checked')].map((box) => box.value);
}

function wire() {
  $('login-form').addEventListener('submit', (event) => {
    event.preventDefault();
    run(async () => {
      const form = {
        username: $('email').value,
        password: $('password').value,
      };
      const result = await api('/auth/login', { method: 'POST', form });
      token = result.access_token;
      sessionStorage.setItem(TOKEN_KEY, token);
      $('password').value = '';
      await load();
    });
  });
  $('sign-out').addEventListener('click', () => {
    token = '';
    sessionStorage.removeItem(TOKEN_KEY);
    me = null;
    view = null;
    load();
  });
  $('site').addEventListener('change', refreshConsolidationList);
  $('site').addEventListener('change', () => {
    const site = siteById(selectedId($('site')));
    if (!site) return;
    const options = surveysForSite(site);
    fill($('survey'), options, (survey) => surveyLabel(survey), (survey) => survey.id, 'Choose a survey');
  });
  for (const id of ['show-heat', 'show-zones']) {
    $(id).addEventListener('change', () => {
      if (view?.kind === 'site') renderConsolidation(view.result);
    });
  }
  $('open-3d').addEventListener('click', () => {
    const surveyId = selectedId($('survey'));
    if (!surveyId) return status('Choose a survey first.');
    view = { kind: '3d', surveyId };
    showView('3d');
    $('viewer').src = `/api/viewer/#survey=${encodeURIComponent(surveyId)}&token=${encodeURIComponent(token)}`;
  });
  $('open-2d').addEventListener('click', () => run(async () => {
    const surveyId = selectedId($('survey'));
    if (!surveyId) return status('Choose a survey first.');
    const [geojson, summary] = await Promise.all([
      api(`/surveys/${surveyId}/geojson`),
      api(`/surveys/${surveyId}/summary`),
    ]);
    const thresholds = summary.floors.find((floor) => floor.thresholds)?.thresholds ||
      { good_dbm: -67, dead_dbm: -80 };
    view = { kind: 'map', thresholds };
    showView('map');
    draw(featureCells(geojson.features), []);
    $('legend').textContent = `Good ≥ ${thresholds.good_dbm} dBm, dead < ${thresholds.dead_dbm} dBm.`;
  }));
  $('open-routers').addEventListener('click', () => run(async () => {
    const surveyId = selectedId($('survey'));
    if (!surveyId) return status('Choose a survey first.');
    const data = await api(`/surveys/${surveyId}/routers`);
    view = { kind: 'routers', thresholds: data.thresholds };
    renderRouters(data);
  }));
  $('open-report').addEventListener('click', () => run(async () => {
    const surveyId = selectedId($('survey'));
    if (!surveyId) return status('Choose a survey first.');
    const facts = await api(`/surveys/${surveyId}/report/facts`);
    view = { kind: 'report', surveyId };
    showReport(facts);
  }));
  $('consolidate').addEventListener('click', () => run(async () => {
    const siteId = selectedId($('site'));
    if (!siteId) return status('Choose a site first.');
    const surveyIds = selectedSurveys();
    if (!surveyIds.length) return status('Select at least one survey.');
    const result = await api(`/sites/${siteId}/consolidate`, {
      method: 'POST', json: { survey_ids: surveyIds },
    });
    renderConsolidation(result);
  }));
  $('create-site').addEventListener('click', () => run(async () => {
    const name = $('site-name').value.trim();
    if (!name) return status('Enter a site name.');
    const buildingIds = [...$('site-buildings').querySelectorAll('input:checked')].map((box) => box.value);
    await api('/sites', {
      method: 'POST', json: { name, building_ids: buildingIds },
    });
    $('site-name').value = '';
    await loadPickers();
  }));
  $('generate-report').addEventListener('click', () => run(async () => {
    if (view?.kind === 'site') {
      const result = await api(`/sites/${view.result.site_id}/report`, {
        method: 'POST', json: { survey_ids: view.result.survey_ids },
      });
      lastReport = result.markdown;
    } else if (view?.surveyId) {
      const result = await api(`/surveys/${view.surveyId}/report`, { method: 'POST' });
      lastReport = result.markdown;
    } else {
      return status('Open a survey or a consolidated view first.');
    }
    $('report-text').textContent = lastReport;
    $('export-report').hidden = false;
  }));
  $('export-report').addEventListener('click', () => {
    if (!lastReport) return;
    const url = URL.createObjectURL(
      new Blob([lastReport], { type: 'text/markdown;charset=utf-8' }),
    );
    const link = document.createElement('a');
    link.href = url;
    link.download = 'signalscape-report.md';
    link.click();
    URL.revokeObjectURL(url);
  });
}

if (typeof document !== 'undefined') {
  wire();
  load();
}
