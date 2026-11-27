// SignalScape browser dashboard (FR-37).
//
// Three steps, left to right: choose what to open, look at it, understand it.
// Every request carries the JWT from browser sign-in and the page holds no
// survey data of its own. All text from the API is written with textContent,
// never as HTML.

import {
  DEFAULT_THRESHOLDS,
  LEVELS,
  aggregateFloors,
  buildHash,
  buildingsForSite,
  cellsFromGrid,
  defaultFloor,
  floorChoices,
  formatArea,
  formatDate,
  formatDateTime,
  formatDbm,
  formatMeters,
  formatPct,
  isProcessed,
  niceScale,
  originOfFeatures,
  parseHash,
  parseInline,
  parseMarkdown,
  sceneFromFeatures,
  surveysForScope,
  toLocal,
} from './lib.mjs';

const TOKEN_KEY = 'signalscape.dashboard.token';
const PAGE_SIZE = 100;
const MINUS = '−';

const $ = (id) => document.getElementById(id);

// --- state -----------------------------------------------------------------

let token = '';
try {
  token = sessionStorage.getItem(TOKEN_KEY) || '';
} catch {
  token = '';
}

const state = {
  me: null,
  sites: [],
  buildings: [],
  surveys: [],
  mode: 'survey',
  siteId: '',
  buildingId: '',
  surveyId: '',
  mergeIds: new Set(),
  view: 'coverage',
  tab: 'summary',
  floor: null,
  network: '',
  layers: { good: true, zones: true, routers: true },
  loaded: { survey: null, campus: null },
  request: 0,
  report: null,
  reportAbort: null,
};

let map = null;
let hoverFloors = new Map();

// --- small DOM helpers -----------------------------------------------------

function el(tag, options = {}, ...children) {
  const node = document.createElement(tag);
  if (options.class) node.className = options.class;
  if (options.text != null) node.textContent = options.text;
  for (const [name, value] of Object.entries(options.attrs || {})) {
    if (value !== false && value != null) node.setAttribute(name, value === true ? '' : value);
  }
  for (const child of children) if (child) node.append(child);
  return node;
}

const siteById = (id) => state.sites.find((site) => site.id === id) || null;
const buildingById = (id) => state.buildings.find((item) => item.id === id) || null;
const surveyById = (id) => state.surveys.find((item) => item.id === id) || null;

function toast(message, kind = 'info') {
  const box = $('toasts');
  while (box.children.length >= 3) box.firstChild.remove();
  const item = el('div', { class: `toast ${kind}`, text: message });
  box.append(item);
  setTimeout(() => item.remove(), kind === 'error' ? 8000 : 4000);
}

// --- API -------------------------------------------------------------------

class ApiError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

async function api(path, { method = 'GET', json, form, signal } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  let body;
  if (json !== undefined) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(json);
  } else if (form) {
    body = new URLSearchParams(form);
  }
  let response;
  try {
    response = await fetch(`/api${path}`, { method, headers, body, signal });
  } catch (error) {
    if (error?.name === 'AbortError') throw error;
    throw new ApiError('Could not reach the server. Check your connection and try again.', 0);
  }
  if (!response.ok) {
    let detail = `${response.status} ${response.statusText}`.trim();
    try {
      const error = await response.json();
      if (error.detail) {
        detail = typeof error.detail === 'string' ? error.detail : 'The request was not accepted.';
      }
    } catch {
      // keep the HTTP status text
    }
    if (response.status === 401 && token && path !== '/auth/login') {
      endSession('Your session ended. Sign in again to continue.');
    }
    throw new ApiError(detail, response.status);
  }
  if (response.status === 204) return null;
  return response.json();
}

async function allPages(path) {
  const items = [];
  for (let page = 1; ; page += 1) {
    const result = await api(`${path}?page=${page}&page_size=${PAGE_SIZE}`);
    items.push(...result.items);
    if (items.length >= result.total || !result.items.length) return items;
  }
}

// --- sign in and out -------------------------------------------------------

function showScreen(name) {
  document.body.dataset.state = name;
}

function endSession(message) {
  token = '';
  try {
    sessionStorage.removeItem(TOKEN_KEY);
  } catch {
    // nothing stored
  }
  abortReport();
  state.me = null;
  state.loaded = { survey: null, campus: null };
  showScreen('auth');
  document.title = 'Sign in · SignalScape';
  if (message) showLoginError(message);
  $('email').focus();
}

function showLoginError(message, fields = []) {
  const box = $('login-error');
  box.textContent = message;
  box.hidden = !message;
  for (const id of ['email', 'password']) {
    $(id).setAttribute('aria-invalid', fields.includes(id) ? 'true' : 'false');
  }
}

async function signIn(event) {
  event.preventDefault();
  const email = $('email').value.trim();
  const password = $('password').value;
  if (!email || !password) {
    const missing = [];
    if (!email) missing.push('email');
    if (!password) missing.push('password');
    showLoginError(
      !email && !password ? 'Enter your email and password.' : `Enter your ${missing[0]}.`,
      missing,
    );
    $(missing[0]).focus();
    return;
  }
  const button = $('login-submit');
  button.disabled = true;
  button.textContent = 'Signing in…';
  showLoginError('');
  try {
    const result = await api('/auth/login', {
      method: 'POST',
      form: { username: email, password },
    });
    token = result.access_token;
    try {
      sessionStorage.setItem(TOKEN_KEY, token);
    } catch {
      // the session lasts until the tab closes either way
    }
    $('password').value = '';
    await start();
  } catch (error) {
    const wrong = error instanceof ApiError && (error.status === 400 || error.status === 401);
    showLoginError(
      wrong ? 'That email and password do not match an account.' : error.message,
      wrong ? ['email', 'password'] : [],
    );
  } finally {
    button.disabled = false;
    button.textContent = 'Sign in';
  }
}

// --- start-up --------------------------------------------------------------

async function start() {
  if (!token) {
    showScreen('auth');
    document.title = 'Sign in \u00B7 SignalScape';
    $('email').focus();
    return;
  }
  try {
    state.me = await api('/auth/me');
  } catch (error) {
    if (token) endSession(error.status === 0 ? error.message : '');
    return;
  }
  $('identity').textContent = state.me.name;
  $('role').textContent = state.me.role;
  $('new-site').hidden = state.me.role !== 'admin';
  showScreen('app');
  document.title = 'SignalScape';
  showState('loading', 'Loading your data…');
  try {
    await loadLists();
  } catch (error) {
    showState('error', 'Could not load your data', error.message, 'Try again', start);
    return;
  }
  applyHash(true);
}

async function loadLists() {
  const [sites, buildings, surveys] = await Promise.all([
    allPages('/sites'),
    allPages('/buildings'),
    allPages('/surveys'),
  ]);
  state.sites = sites;
  state.buildings = buildings;
  state.surveys = surveys;
}

// --- address bar -----------------------------------------------------------

function currentHash() {
  return buildHash({
    mode: state.mode === 'campus' ? 'campus' : '',
    site: state.siteId,
    building: state.mode === 'survey' ? state.buildingId : '',
    survey: state.mode === 'survey' ? state.surveyId : '',
    view: state.view === 'coverage' ? '' : state.view,
  });
}

function writeHash() {
  const next = currentHash();
  if (next !== location.hash) history.replaceState(null, '', next || location.pathname);
}

function applyHash(initial) {
  const wanted = parseHash(location.hash);
  state.mode = wanted.mode || 'survey';
  state.siteId = siteById(wanted.site) ? wanted.site : '';
  state.buildingId = buildingById(wanted.building) ? wanted.building : '';
  state.view = wanted.view || 'coverage';
  const survey = surveyById(wanted.survey);
  state.surveyId = survey ? survey.id : '';
  if (survey && !state.buildingId) state.buildingId = '';
  $('mode-campus').checked = state.mode === 'campus';
  $('mode-survey').checked = state.mode === 'survey';
  if (state.mode === 'campus' && !state.siteId) state.siteId = state.sites[0]?.id || '';
  resetMerge();
  renderScope();
  syncViewTabs();
  if (state.mode === 'survey') {
    if (!state.surveyId && initial) {
      // A sensible start: the newest survey that is ready to look at.
      const first = surveysForScope(state.surveys, scopeOf()).find(isProcessed);
      if (first) state.surveyId = first.id;
    }
    renderScope();
    if (state.surveyId) loadSurvey();
    else showEmpty();
  } else {
    showEmpty();
  }
  writeHash();
}

// --- choose ----------------------------------------------------------------

function scopeOf() {
  return {
    site: state.mode === 'campus' || state.siteId ? siteById(state.siteId) : null,
    buildingId: state.mode === 'survey' ? state.buildingId : '',
  };
}

function resetMerge() {
  const ready = surveysForScope(state.surveys, { site: siteById(state.siteId) }).filter(isProcessed);
  state.mergeIds = new Set(ready.map((survey) => survey.id));
}

function fillSelect(select, items, placeholder, selected) {
  select.replaceChildren();
  if (placeholder) select.add(new Option(placeholder, ''));
  for (const [value, label] of items) select.add(new Option(label, value));
  select.value = selected && items.some(([value]) => value === selected) ? selected : (placeholder ? '' : (items[0]?.[0] ?? ''));
}

function renderScope() {
  const campus = state.mode === 'campus';
  $('survey-block').hidden = campus;
  $('campus-block').hidden = !campus;
  $('building-field').hidden = campus;
  $('merge').hidden = !campus;

  fillSelect(
    $('site'),
    state.sites.map((site) => [site.id, site.name]),
    campus ? '' : 'All sites',
    state.siteId,
  );
  if (campus && !state.sites.length) {
    $('site').add(new Option('No sites yet', ''));
  }
  const site = siteById(state.siteId);
  const buildings = buildingsForSite(state.buildings, site);
  fillSelect(
    $('building'),
    buildings.map((building) => [building.id, building.name]),
    'All buildings',
    state.buildingId,
  );
  if (state.buildingId && !buildings.some((item) => item.id === state.buildingId)) {
    state.buildingId = '';
  }
  campus ? renderMergeList() : renderSurveyList();
  updateMergeButton();
}

function surveyChoice({ type, name, survey, checked, onChange }) {
  const building = buildingById(survey.building_id);
  const ready = isProcessed(survey);
  const input = el('input', {
    attrs: { type, name, value: survey.id, checked: checked || false, disabled: !ready },
  });
  input.addEventListener('change', () => onChange(input.checked));
  const body = el(
    'span',
    { class: 'choice-body' },
    el(
      'span',
      {},
      el('span', { class: 'choice-title', text: building?.name || 'Unknown building' }),
      el('span', {
        class: 'choice-meta',
        text: `${formatDateTime(survey.started_at)} · ${survey.surveyor_name}`,
      }),
    ),
    ready ? null : el('span', { class: 'tag', text: 'Not processed' }),
  );
  const label = el('label', { class: `choice${type === 'checkbox' ? ' check' : ''}` }, input, body);
  if (!ready) label.title = 'Process this survey in the app before opening it here.';
  return label;
}

function renderSurveyList() {
  const list = $('survey');
  list.replaceChildren();
  const items = surveysForScope(state.surveys, scopeOf());
  const ready = items.filter(isProcessed).length;
  $('survey-count').textContent = items.length ? `${ready} of ${items.length} ready` : '';
  if (!items.length) {
    list.append(
      el('p', {
        class: 'empty-note',
        text: state.surveys.length
          ? 'No surveys here. Try another site or building.'
          : 'No surveys yet. Walk one with the phone app and process it.',
      }),
    );
    return;
  }
  for (const survey of items) {
    list.append(
      surveyChoice({
        type: 'radio',
        name: 'survey',
        survey,
        checked: survey.id === state.surveyId,
        onChange: (on) => on && chooseSurvey(survey.id),
      }),
    );
  }
}

function renderMergeList() {
  const list = $('merge-list');
  list.replaceChildren();
  const site = siteById(state.siteId);
  if (!site) {
    list.append(
      el('p', {
        class: 'empty-note',
        text: state.me?.role === 'admin'
          ? 'Create a site first. A site groups buildings so their surveys can be merged.'
          : 'No site is set up yet. An admin needs to create one.',
      }),
    );
    return;
  }
  const items = surveysForScope(state.surveys, { site });
  if (!items.length) {
    list.append(el('p', { class: 'empty-note', text: 'No surveys in this site’s buildings yet.' }));
    return;
  }
  for (const survey of items) {
    list.append(
      surveyChoice({
        type: 'checkbox',
        name: 'merge',
        survey,
        checked: state.mergeIds.has(survey.id),
        onChange: (on) => {
          if (on) state.mergeIds.add(survey.id);
          else state.mergeIds.delete(survey.id);
          updateMergeButton();
        },
      }),
    );
  }
}

function updateMergeButton() {
  const count = state.mergeIds.size;
  const button = $('merge');
  button.textContent = count ? `Merge ${count} survey${count === 1 ? '' : 's'}` : 'Choose surveys to merge';
  button.disabled = !count || !state.siteId;
}

function setMerge(all) {
  const ready = surveysForScope(state.surveys, { site: siteById(state.siteId) }).filter(isProcessed);
  state.mergeIds = new Set(all ? ready.map((survey) => survey.id) : []);
  renderMergeList();
  updateMergeButton();
}

function chooseSurvey(id) {
  state.surveyId = id;
  writeHash();
  loadSurvey();
}

// --- stage states ----------------------------------------------------------

function showState(kind, title, text = '', actionLabel = '', action = null) {
  const box = $('state');
  box.hidden = false;
  box.className = `state ${kind === 'loading' ? '' : kind === 'error' ? 'error' : 'clear'}`.trim();
  $('state-spinner').hidden = kind !== 'loading';
  $('state-title').textContent = title;
  $('state-text').textContent = text;
  const button = $('state-action');
  button.hidden = !actionLabel;
  button.textContent = actionLabel;
  button.onclick = action;
  $('canvas-wrap').setAttribute('aria-busy', kind === 'loading' ? 'true' : 'false');
}

function hideState() {
  $('state').hidden = true;
  $('canvas-wrap').setAttribute('aria-busy', 'false');
}

function showEmpty() {
  clearStage();
  if (state.mode === 'campus') {
    const site = siteById(state.siteId);
    showState(
      'empty',
      site ? `Merge surveys for ${site.name}` : 'No site to merge yet',
      site
        ? 'Tick the surveys you want, then choose Merge. Their readings are combined into one coverage map.'
        : 'A site groups buildings so their surveys can be merged into one campus map.',
    );
  } else {
    const any = state.surveys.some(isProcessed);
    showState(
      'empty',
      any ? 'Choose a survey' : 'Nothing to show yet',
      any
        ? 'Pick one on the left to see its coverage, routers and a written report.'
        : 'Surveys appear here once they are processed in the phone app.',
    );
  }
}

function clearStage() {
  map.clear();
  $('title').textContent = state.mode === 'campus' ? 'Campus merge' : 'Choose a survey';
  $('subtitle').textContent = '';
  $('floors').replaceChildren();
  $('legend').hidden = true;
  $('scale').hidden = true;
  $('hover').hidden = true;
  $('map-desc').textContent = '';
  renderCrumbs(null);
  renderSummary(null);
  renderRoutersPanel(null);
  resetReport();
  document.title = 'SignalScape';
  setViewAvailability();
}

// --- loading data ----------------------------------------------------------

async function loadSurvey() {
  const id = state.surveyId;
  const survey = surveyById(id);
  if (!survey) return showEmpty();
  const cached = state.loaded.survey;
  if (cached && cached.id === id) return render(cached);
  const request = ++state.request;
  showState('loading', 'Loading coverage…', survey ? `${buildingById(survey.building_id)?.name || ''}` : '');
  try {
    const [geo, facts] = await Promise.all([
      api(`/surveys/${id}/geojson`),
      api(`/surveys/${id}/report/facts`),
    ]);
    if (request !== state.request) return;
    const origin =
      originOfFeatures(geo.features) || { lat: survey.origin_lat, lng: survey.origin_lng };
    const scene = sceneFromFeatures(geo.features, facts.thresholds, origin);
    state.loaded.survey = {
      kind: 'survey',
      id,
      title: facts.title,
      subtitle: `${formatDateTime(survey.started_at)} · walked by ${survey.surveyor_name}`,
      thresholds: facts.thresholds,
      floors: facts.floors,
      routerCount: facts.access_point_count,
      placedCount: facts.determined_access_point_count,
      lowCount: facts.low_confidence_count,
      origin,
      scene,
      routers: null,
      report: null,
    };
    render(state.loaded.survey);
  } catch (error) {
    if (request !== state.request) return;
    showState('error', 'Could not open this survey', explain(error), 'Try again', loadSurvey);
  }
}

async function loadCampus() {
  const site = siteById(state.siteId);
  const ids = [...state.mergeIds];
  if (!site || !ids.length) return;
  const request = ++state.request;
  clearStage();
  showState('loading', 'Merging surveys…', `Combining ${ids.length} survey${ids.length === 1 ? '' : 's'} for ${site.name}.`);
  $('merge').disabled = true;
  try {
    const result = await api(`/sites/${site.id}/consolidate`, { method: 'POST', json: { survey_ids: ids } });
    if (request !== state.request) return;
    const grids = result.grids.some((grid) => grid.bssid == null)
      ? result.grids.filter((grid) => grid.bssid == null)
      : result.grids;
    const first = grids[0];
    const located = result.access_points.find((ap) => ap.lat != null);
    const origin = first
      ? { lat: first.origin_lat, lng: first.origin_lng }
      : located
        ? { lat: located.lat, lng: located.lng }
        : { lat: 0, lng: 0 };
    const cells = grids.flatMap((grid) => cellsFromGrid(grid, result.thresholds, origin, grid.floor_level));
    const pins = result.access_points
      .filter((ap) => ap.lat != null && ap.lng != null)
      .map((ap) => {
        const point = toLocal(ap.lat, ap.lng, origin);
        return {
          x: point.x,
          y: point.y,
          floor: ap.floor_level,
          label: ap.ssid || ap.bssid,
          bssid: ap.bssid,
          rssi: ap.max_rssi_dbm,
          low: Boolean(ap.low_confidence),
          confidence: ap.confidence,
          kind: 'ap',
        };
      });
    state.loaded.campus = {
      kind: 'campus',
      id: site.id,
      title: site.name,
      subtitle: `${ids.length} survey${ids.length === 1 ? '' : 's'} merged · ${formatDateTime(result.computed_at)}`,
      thresholds: result.thresholds,
      floors: result.floors,
      routerCount: result.access_points.length,
      placedCount: result.access_points.filter((ap) => ap.position_determined).length,
      lowCount: result.access_points.filter((ap) => ap.low_confidence).length,
      surveyIds: result.survey_ids,
      origin,
      scene: { cells, pins },
      routers: null,
      report: null,
    };
    render(state.loaded.campus);
  } catch (error) {
    if (request !== state.request) return;
    showState('error', 'Could not merge these surveys', explain(error), 'Try again', loadCampus);
  } finally {
    updateMergeButton();
  }
}

function explain(error) {
  if (error instanceof ApiError && error.status === 403) return 'You do not have access to this. Ask an admin.';
  if (error instanceof ApiError && error.status === 404) return 'It was not found. It may have been deleted.';
  if (error instanceof ApiError && error.status === 409) return error.message;
  return error.message || 'Something went wrong.';
}

// --- render the loaded data ------------------------------------------------

function currentData() {
  return state.loaded[state.mode];
}

function render(data) {
  $('title').textContent = data.title;
  $('subtitle').textContent = data.subtitle;
  $('subtitle').title = data.subtitle;
  document.title = `${data.title} · SignalScape`;
  renderCrumbs(data);
  renderHints(data);
  renderSummary(data);
  renderReportFor(data);
  setViewAvailability();
  setView(state.view);
}

function renderCrumbs(data) {
  const list = $('crumbs');
  list.replaceChildren();
  const parts = [];
  const site = siteById(state.siteId);
  if (site) parts.push(site.name);
  if (data?.kind === 'survey') {
    const survey = surveyById(data.id);
    const building = buildingById(survey?.building_id);
    if (building && !parts.includes(building.name)) parts.push(building.name);
    if (survey) parts.push(formatDate(survey.started_at));
  } else if (data?.kind === 'campus') {
    if (!parts.length) parts.push(data.title);
    parts.push('Campus merge');
  }
  parts.forEach((part, index) => {
    const item = el('li', { text: part });
    if (index === parts.length - 1) item.setAttribute('aria-current', 'page');
    list.append(item);
  });
}

function renderFloors(choices, has) {
  const box = $('floors');
  box.replaceChildren();
  for (const choice of choices) {
    const usable = has.has(choice.level);
    const chip = el('button', {
      class: 'chip',
      text: choice.label,
      attrs: {
        type: 'button',
        'aria-pressed': choice.level === state.floor ? 'true' : 'false',
        disabled: !usable,
        title: usable ? false : 'Nothing to show for this floor in this view.',
      },
    });
    chip.dataset.level = String(choice.level);
    chip.addEventListener('click', () => setFloor(choice.level));
    box.append(chip);
  }
}

// Floors come from the figures, but a view may draw only some of them. Chips
// for floors with nothing to draw are disabled, and the selection moves to a
// floor that has something, so the map is never silently empty.
function applyFloors(data, scene) {
  const has = new Set();
  for (const item of [...scene.cells, ...scene.pins, ...(scene.lines || [])]) {
    if (item.floor != null) has.add(item.floor);
  }
  const choices = floorChoices(data.floors);
  for (const level of has) {
    if (!choices.some((choice) => choice.level === level)) {
      choices.push({ level, label: `Level ${level}`, area: 0 });
    }
  }
  choices.sort((a, b) => a.level - b.level);
  hoverFloors = new Map(choices.map((choice) => [choice.level, choice.label]));
  if (!has.has(state.floor)) {
    state.floor = defaultFloor(choices.filter((choice) => has.has(choice.level)));
  }
  renderFloors(choices, has);
  map.floor = state.floor;
}

function setFloor(level) {
  state.floor = level;
  for (const chip of $('floors').children) {
    chip.setAttribute('aria-pressed', chip.dataset.level === String(level) ? 'true' : 'false');
  }
  map.setFloor(level);
  updateLegend();
  describeMap();
}

function renderHints(data) {
  const t = data.thresholds || DEFAULT_THRESHOLDS;
  $('hint-good').textContent = `${formatDbm(t.good_dbm)} or stronger`;
  $('hint-zones').textContent = `Weak ${formatDbm(t.dead_dbm)} to ${formatDbm(t.good_dbm)}; dead below, hatched`;
}

function describeMap() {
  const data = currentData();
  if (!data) return;
  const floorName = hoverFloors.get(state.floor) || 'This floor';
  const floor = data.floors.filter((item) => item.floor_level === state.floor);
  const sum = aggregateFloors(floor);
  $('map-desc').textContent = sum.hasData
    ? `${floorName} of ${data.title}: ${formatPct(sum.good)} good, ${formatPct(sum.fair)} weak, ${formatPct(sum.dead)} dead. The Summary panel lists the figures.`
    : `${floorName} of ${data.title}: no coverage data.`;
}

// --- summary panel ---------------------------------------------------------

function levelKey(level) {
  return el('span', { class: `key ${level}`, attrs: { 'aria-hidden': 'true' } });
}

function renderSummary(data) {
  const body = $('summary-body');
  body.replaceChildren();
  if (!data) {
    body.append(
      el('p', { class: 'empty-note', text: 'Open a survey to see how much of it has good, weak and dead signal.' }),
    );
    return;
  }
  const t = data.thresholds || DEFAULT_THRESHOLDS;
  const sum = aggregateFloors(data.floors);

  const hero = el('div', { class: 'stat-hero' });
  if (sum.hasData) {
    hero.append(
      el(
        'div',
        { class: 'big' },
        el('span', { class: 'num', text: formatPct(sum.good) }),
        el('span', { class: 'muted', text: 'of the surveyed area has good signal' }),
      ),
    );
    const bar = el('div', { class: 'stack-bar', attrs: { role: 'img', 'aria-label': `${formatPct(sum.good)} good, ${formatPct(sum.fair)} weak, ${formatPct(sum.dead)} dead` } });
    for (const [level, value] of [['good', sum.good], ['fair', sum.fair], ['dead', sum.dead]]) {
      const part = el('span', { class: level });
      part.style.flexGrow = String(Math.max(value, 0.0001));
      if (value <= 0) part.hidden = true;
      bar.append(part);
    }
    hero.append(bar);
    const ranges = {
      good: `${formatDbm(t.good_dbm)} or stronger`,
      fair: `${formatDbm(t.dead_dbm)} to ${formatDbm(t.good_dbm)}`,
      dead: `below ${formatDbm(t.dead_dbm)}`,
    };
    const list = el('div', { class: 'share-list' });
    for (const [level, value] of [['good', sum.good], ['fair', sum.fair], ['dead', sum.dead]]) {
      list.append(
        el(
          'div',
          { class: 'share-row' },
          levelKey(level),
          el('span', { text: LEVELS[level].label }),
          el('span', { class: 'range', text: ranges[level] }),
          el('span', { class: 'num', text: formatPct(value) }),
        ),
      );
    }
    hero.append(list);
  } else {
    hero.append(el('p', { class: 'muted', text: 'This has no processed coverage yet. Run Process in the app, then reopen it.' }));
  }
  body.append(hero);

  const tiles = el('div', { class: 'tiles' });
  const tile = (value, label) =>
    tiles.append(el('div', { class: 'tile' }, el('span', { class: 'num', text: value }), el('span', { text: label })));
  tile(sum.readings.toLocaleString('en-US'), 'Readings');
  tile(formatArea(sum.area), 'Surveyed area');
  tile(`${data.placedCount} of ${data.routerCount}`, 'Routers placed');
  tile(String(data.lowCount), 'Low confidence');
  body.append(tiles);

  if (data.floors.length) {
    const table = el('table', { class: 'table' });
    table.append(
      el(
        'thead',
        {},
        el(
          'tr',
          {},
          el('th', { text: 'Floor', attrs: { scope: 'col' } }),
          el('th', { class: 'r', text: 'Good', attrs: { scope: 'col' } }),
          el('th', { class: 'r', text: 'Weak', attrs: { scope: 'col' } }),
          el('th', { class: 'r', text: 'Dead', attrs: { scope: 'col' } }),
        ),
      ),
    );
    const rows = el('tbody');
    for (const floor of [...data.floors].sort((a, b) => a.floor_level - b.floor_level)) {
      const open = el('button', { class: 'link', text: floor.floor_label, attrs: { type: 'button', 'aria-label': `Show ${floor.floor_label} on the map` } });
      open.addEventListener('click', () => {
        if (state.view === '3d') setView('coverage');
        setFloor(floor.floor_level);
      });
      rows.append(
        el(
          'tr',
          {},
          el('td', {}, open),
          el('td', { class: 'r', text: formatPct(floor.good_pct) }),
          el('td', { class: 'r', text: formatPct(floor.fair_pct) }),
          el('td', { class: 'r', text: formatPct(floor.dead_pct) }),
        ),
      );
    }
    table.append(rows);
    body.append(table);
  }
  body.append(
    el('p', {
      class: 'muted small-text',
      text: `Good is ${formatDbm(t.good_dbm)} or stronger; dead is below ${formatDbm(t.dead_dbm)}. Shares are weighted by surveyed area. You can change the limits in the app’s settings.`,
    }),
  );
}

// --- views -----------------------------------------------------------------

function setViewAvailability() {
  const campus = state.mode === 'campus';
  const none = !currentData();
  const rules = {
    coverage: none ? 'Choose data first.' : '',
    routers: none ? 'Choose data first.' : campus ? 'Router coverage opens for one survey at a time.' : '',
    '3d': none ? 'Choose data first.' : campus ? '3D opens for one survey at a time.' : '',
  };
  for (const tab of $('view-tabs').children) {
    const reason = rules[tab.dataset.view];
    tab.disabled = Boolean(reason);
    if (reason) tab.title = reason;
    else tab.removeAttribute('title');
  }
  $('merge').hidden = !campus;
}

function syncViewTabs() {
  for (const tab of $('view-tabs').children) {
    const on = tab.dataset.view === state.view;
    tab.setAttribute('aria-selected', on ? 'true' : 'false');
    tab.tabIndex = on ? 0 : -1;
  }
}

function setView(view) {
  const data = currentData();
  if (!data) return;
  if (data.kind === 'campus' && view !== 'coverage') view = 'coverage';
  state.view = view;
  syncViewTabs();
  writeHash();
  const flat = view !== '3d';
  $('map').hidden = !flat;
  $('viewer').hidden = flat;
  $('floors').hidden = !flat;
  document.querySelector('.zoom').hidden = !flat;
  $('network-field').hidden = view !== 'routers';
  if (view === 'routers' && state.tab !== 'routers') setTab('routers');
  else if (view !== 'routers' && state.tab === 'routers') setTab('summary');
  $('layers-note').textContent = flat
    ? ''
    : 'The 3D view has its own layer controls, inside the view.';
  if (view === '3d') {
    hideState();
    $('legend').hidden = true;
    $('scale').hidden = true;
    $('hover').hidden = true;
    const target = `/api/viewer/#survey=${encodeURIComponent(data.id)}&token=${encodeURIComponent(token)}`;
    if ($('viewer').dataset.survey !== data.id) {
      $('viewer').dataset.survey = data.id;
      $('viewer').src = target;
    }
    return;
  }
  if (view === 'routers') return openRouters(data);
  hideState();
  map.setLayers(state.layers);
  applyFloors(data, data.scene);
  map.setScene({ cells: data.scene.cells, pins: data.scene.pins, lines: [] });
  if (!data.scene.cells.length) {
    showState('empty', 'No coverage to draw', 'This survey has no coverage cells yet. Process it in the app and reopen it.');
  }
  updateLegend();
  describeMap();
}

// --- routers ---------------------------------------------------------------

async function openRouters(data) {
  if (!data.routers) {
    const request = ++state.request;
    showState('loading', 'Finding routers…');
    try {
      data.routers = await api(`/surveys/${data.id}/routers`);
    } catch (error) {
      if (request !== state.request) return;
      showState('error', 'Could not load routers', explain(error), 'Try again', () => openRouters(data));
      return;
    }
    if (request !== state.request) return;
  }
  hideState();
  renderNetworkSelect(data);
  renderRoutersPanel(data);
  drawRouters(data);
}

function networksOf(data) {
  return data.routers?.extended_networks || [];
}

function renderNetworkSelect(data) {
  const networks = networksOf(data);
  fillSelect(
    $('network'),
    networks.map((network) => [network.ssid, `${network.ssid} (${network.router_count})`]),
    'All routers',
    state.network,
  );
  state.network = $('network').value;
}

function drawRouters(data) {
  const routers = data.routers;
  const cells = [];
  const pins = [];
  const lines = [];
  const network = networksOf(data).find((item) => item.ssid === state.network);
  const addPin = (router, level, role) => {
    if (router.lat == null || router.lng == null) return;
    const point = toLocal(router.lat, router.lng, data.origin);
    pins.push({
      x: point.x,
      y: point.y,
      floor: level,
      label: router.label || `Router ${router.number}`,
      number: router.number,
      role,
      low: Boolean(router.low_confidence),
      rssi: router.max_rssi_dbm,
      confidence: router.confidence,
      kind: 'router',
    });
  };
  const addLinks = (floor, level, list) => {
    const at = new Map(floor.routers.filter((r) => r.lat != null).map((r) => [r.router_id, r]));
    for (const link of list) {
      const a = at.get(link.from_router);
      const b = at.get(link.to_router);
      if (!a || !b) continue;
      const p = toLocal(a.lat, a.lng, data.origin);
      const q = toLocal(b.lat, b.lng, data.origin);
      lines.push({ ax: p.x, ay: p.y, bx: q.x, by: q.y, floor: level, status: link.status });
    }
  };
  if (network) {
    for (const floor of network.floors) {
      const grid = floor.coverage || floor.gaps;
      if (grid) cells.push(...cellsFromGrid(grid, data.thresholds, data.origin, floor.floor_level));
      for (const router of floor.routers) addPin(router, floor.floor_level, router.role);
      addLinks(floor, floor.floor_level, floor.links);
    }
  } else {
    cells.push(...data.scene.cells);
    for (const floor of routers.floors) {
      for (const router of floor.routers) addPin(router, floor.floor_level, null);
      for (const chain of floor.chains) addLinks(floor, floor.floor_level, chain.links);
    }
  }
  map.setLayers({ ...state.layers, routers: true });
  applyFloors(data, { cells, pins, lines });
  map.setScene({ cells, pins, lines });
  updateLegend();
  describeMap();
  if (!pins.length) {
    showState(
      'empty',
      'No router positions yet',
      'A router appears once at least one reading near it is strong. Walk closer to it and process again.',
    );
  }
}

function renderRoutersPanel(data) {
  const body = $('routers-body');
  body.replaceChildren();
  if (!data?.routers) {
    body.append(
      el('p', {
        class: 'empty-note',
        text: data?.kind === 'campus'
          ? 'Router coverage opens for one survey at a time. Choose the One survey tab.'
          : 'Choose the Routers view to find routers, and the links between those that share a network name.',
      }),
    );
    return;
  }
  const routers = data.routers;
  body.append(
    el('p', {
      class: 'muted',
      text: `${routers.router_count} router${routers.router_count === 1 ? '' : 's'} found from ${routers.bssid_count} network radios.`,
    }),
  );
  const networks = networksOf(data);
  if (!networks.length) {
    body.append(
      el('p', { class: 'empty-note', text: 'No network name is served by more than one router, so there are no extenders to compare.' }),
    );
  }
  networks.forEach((network, index) => {
    const open = state.network ? network.ssid === state.network : index === 0;
    const details = el('details', { class: 'net', attrs: { open } });
    details.append(
      el('summary', {}, el('span', { text: network.ssid }), el('span', { class: 'tag', text: `${network.router_count} routers` })),
    );
    const inner = el('div', { class: 'net-body' });
    for (const floor of network.floors) {
      const names = new Map(floor.routers.map((router) => [router.router_id, router.label]));
      const group = el('div', {});
      group.append(el('h4', { text: floor.floor_label }));
      const list = el('div', { class: 'rows' });
      for (const router of floor.routers) {
        const placed = router.lat != null;
        list.append(
          el(
            'div',
            { class: 'row' },
            el('span', { class: `pin${router.role === 'likely_main' ? ' main' : ''}${router.low_confidence ? ' low' : ''}`, text: String(router.number), attrs: { 'aria-hidden': 'true' } }),
            el('span', { text: `${router.label} · ${router.role === 'likely_main' ? 'likely main' : 'extender'}` }),
            el('span', { class: 'num', text: placed ? formatDbm(router.max_rssi_dbm) : 'not placed' }),
          ),
        );
      }
      group.append(list);
      if (floor.links.length) {
        const links = el('div', { class: 'rows' });
        for (const link of floor.links) {
          const label = { covered: 'Covered', weak: 'Weak', dead: 'Dead', no_data: 'No data' }[link.status] || link.status;
          const trouble = link.dead_m > 0 ? `${formatMeters(link.dead_m)} dead` : link.weak_m > 0 ? `${formatMeters(link.weak_m)} weak` : formatMeters(link.length_m);
          links.append(
            el(
              'div',
              { class: 'row' },
              el('span', { text: `${names.get(link.from_router) || '?'} to ${names.get(link.to_router) || '?'}` }),
              el('span', { class: `status ${link.status}`, text: label }),
              el('span', { class: 'num', text: trouble }),
            ),
          );
        }
        group.append(el('h4', { text: 'Links', class: 'spaced' }), links);
      }
      inner.append(group);
    }
    details.append(inner);
    details.addEventListener('toggle', () => {
      if (details.open && $('network').value !== network.ssid) {
        $('network').value = network.ssid;
        state.network = network.ssid;
        drawRouters(data);
      }
    });
    body.append(details);
  });
  if (routers.main_heuristic) {
    body.append(el('p', { class: 'muted small-text', text: `${routers.main_heuristic} This is a guess from signal strength, not something the scan can tell.` }));
  }
}

// --- legend, scale, hover --------------------------------------------------

function legendRow(keyClass, name, range) {
  const row = el('span', { class: 'legend-row' }, el('span', { class: `key ${keyClass}`, attrs: { 'aria-hidden': 'true' } }), el('span', { text: name }));
  if (range) row.append(el('span', { class: 'range', text: range }));
  return row;
}

function legendGroup(title, ...rows) {
  return el('div', { class: 'legend-group', attrs: { role: 'group', 'aria-label': title } }, el('span', { class: 'legend-title', text: title }), ...rows);
}

function updateLegend() {
  const data = currentData();
  const box = $('legend');
  box.replaceChildren();
  if (!data || state.view === '3d' || !data.scene) {
    box.hidden = true;
    return;
  }
  const t = data.thresholds || DEFAULT_THRESHOLDS;
  const n = (value) => formatDbm(value).replace(' dBm', '');
  box.append(
    legendGroup(
      'Signal, dBm',
      legendRow('good', 'Good', `\u2265 ${n(t.good_dbm)}`),
      legendRow('fair', 'Weak', `${n(t.dead_dbm)} to ${n(t.good_dbm)}`),
      legendRow('dead', 'Dead', `< ${n(t.dead_dbm)}`),
    ),
  );
  if (state.view === 'routers') {
    box.append(legendGroup('Routers', legendRow('router main', 'Likely main'), legendRow('router', 'Other')));
    box.append(legendGroup('Links', legendRow('line covered', 'Covered'), legendRow('line weak', 'Part weak'), legendRow('line dead', 'Part dead')));
  } else if (state.layers.routers && data.scene.pins.length) {
    box.append(legendGroup('Routers', legendRow('router', 'Router')));
  }
  box.hidden = false;
}

function onScale(metersPerPixel) {
  const scale = niceScale(metersPerPixel);
  const box = $('scale');
  if (!scale.meters || !currentData() || state.view === '3d') {
    box.hidden = true;
    return;
  }
  box.hidden = false;
  $('scale-bar').style.width = `${Math.round(scale.px)}px`;
  $('scale-label').textContent = scale.label;
}

function onHover(hit) {
  const box = $('hover');
  if (!hit) {
    box.hidden = true;
    return;
  }
  const data = currentData();
  box.replaceChildren();
  if (hit.pin) {
    const pin = hit.pin;
    box.append(el('strong', { text: pin.label }));
    const role = pin.role === 'likely_main' ? 'Likely main router' : pin.role === 'extender' ? 'Extender' : 'Router';
    box.append(el('span', { text: `${role}${pin.number != null ? ` ${pin.number}` : ''}` }));
    if (pin.rssi != null) box.append(el('span', { text: `Strongest reading ${formatDbm(pin.rssi)}` }));
    box.append(el('span', { text: pin.low ? 'Low confidence in this position' : 'Position estimated from readings' }));
  } else {
    const cell = hit.cell;
    box.append(el('strong', { class: 'num', text: formatDbm(cell.rssi) }));
    box.append(
      el('span', { class: 'level' }, levelKey(cell.level), el('span', { text: LEVELS[cell.level].label })),
    );
    box.append(el('span', { text: hoverFloors.get(cell.floor) || '' }));
  }
  box.hidden = false;
  const wrap = $('canvas-wrap');
  const x = Math.min(hit.px + 16, wrap.clientWidth - box.offsetWidth - 8);
  const y = hit.py + 16 + box.offsetHeight > wrap.clientHeight ? hit.py - box.offsetHeight - 12 : hit.py + 16;
  box.style.transform = `translate(${Math.max(8, x)}px, ${Math.max(8, y)}px)`;
}

// --- report ----------------------------------------------------------------

function abortReport() {
  if (state.reportAbort) state.reportAbort.abort();
  state.reportAbort = null;
}

function resetReport() {
  abortReport();
  $('report-doc').hidden = true;
  $('report-doc').replaceChildren();
  $('report-status').textContent = '';
  for (const id of ['cancel-report', 'copy-report', 'export-report']) $(id).hidden = true;
  $('generate-report').disabled = !currentData();
  $('generate-report').textContent = 'Write report';
  state.report = null;
}

function renderReportFor(data) {
  resetReport();
  if (data.report) showReport(data.report);
}

function inlineNodes(text) {
  return parseInline(text).map((part) => {
    if (part.type === 'strong') return el('strong', { text: part.text });
    if (part.type === 'em') return el('em', { text: part.text });
    if (part.type === 'code') return el('code', { text: part.text });
    return document.createTextNode(part.text);
  });
}

function appendInline(node, text) {
  for (const child of inlineNodes(text)) node.append(child);
  return node;
}

function showReport(markdown) {
  const doc = $('report-doc');
  doc.replaceChildren();
  for (const block of parseMarkdown(markdown)) {
    if (block.type === 'heading') {
      doc.append(appendInline(el(`h${Math.min(block.level, 3)}`), block.text));
    } else if (block.type === 'paragraph') {
      doc.append(appendInline(el('p'), block.text));
    } else if (block.type === 'list') {
      const list = el(block.ordered ? 'ol' : 'ul');
      for (const item of block.items) list.append(appendInline(el('li'), item));
      doc.append(list);
    } else if (block.type === 'rule') {
      doc.append(el('hr'));
    } else if (block.type === 'table') {
      const table = el('table', { class: 'table' });
      const head = el('tr');
      block.header.forEach((cell, i) => {
        head.append(appendInline(el('th', { class: block.align[i] === 'right' ? 'r' : '', attrs: { scope: 'col' } }), cell));
      });
      table.append(el('thead', {}, head));
      const rows = el('tbody');
      for (const row of block.rows) {
        const tr = el('tr');
        row.forEach((cell, i) => tr.append(appendInline(el('td', { class: block.align[i] === 'right' ? 'r' : '' }), cell)));
        rows.append(tr);
      }
      table.append(rows);
      doc.append(table);
    }
  }
  doc.hidden = false;
  state.report = markdown;
  $('copy-report').hidden = false;
  $('export-report').hidden = false;
  $('generate-report').textContent = 'Write again';
}

async function generateReport() {
  const data = currentData();
  if (!data) return;
  abortReport();
  const controller = new AbortController();
  state.reportAbort = controller;
  const button = $('generate-report');
  button.disabled = true;
  $('cancel-report').hidden = false;
  $('report-status').textContent = 'Writing the report. This can take up to a minute.';
  try {
    const result =
      data.kind === 'campus'
        ? await api(`/sites/${data.id}/report`, { method: 'POST', json: { survey_ids: data.surveyIds }, signal: controller.signal })
        : await api(`/surveys/${data.id}/report`, { method: 'POST', signal: controller.signal });
    data.report = result.markdown;
    showReport(result.markdown);
    $('report-status').textContent = `Written ${formatDateTime(result.generated_at)}.`;
  } catch (error) {
    if (error?.name === 'AbortError') {
      $('report-status').textContent = 'Cancelled.';
    } else if (error instanceof ApiError && error.status === 503) {
      $('report-status').textContent = `${error.message} The figures in Summary are still correct.`;
    } else {
      $('report-status').textContent = explain(error);
    }
  } finally {
    state.reportAbort = null;
    button.disabled = false;
    $('cancel-report').hidden = true;
  }
}

async function copyReport() {
  if (!state.report) return;
  try {
    await navigator.clipboard.writeText(state.report);
    toast('Report copied as Markdown.');
  } catch {
    toast('Copying was blocked. Use Download instead.', 'error');
  }
}

function downloadReport() {
  const data = currentData();
  if (!state.report || !data) return;
  const slug = data.title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'report';
  const url = URL.createObjectURL(new Blob([state.report], { type: 'text/markdown;charset=utf-8' }));
  const link = el('a', { attrs: { href: url, download: `signalscape-${slug}.md` } });
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// --- inspector tabs --------------------------------------------------------

function setTab(name) {
  state.tab = name;
  for (const tab of $('inspector-tabs').children) {
    const on = tab.dataset.tab === name;
    tab.setAttribute('aria-selected', on ? 'true' : 'false');
    tab.tabIndex = on ? 0 : -1;
  }
  const panels = { summary: 'panel-summary', layers: 'panel-layers', routers: 'panel-routers', report: 'report' };
  for (const [key, id] of Object.entries(panels)) $(id).hidden = key !== name;
}

function wireTabs(container, activate) {
  container.addEventListener('keydown', (event) => {
    const tabs = [...container.children].filter((tab) => !tab.disabled && !tab.hidden);
    const at = tabs.indexOf(document.activeElement);
    if (at < 0) return;
    let next = -1;
    if (event.key === 'ArrowRight') next = (at + 1) % tabs.length;
    else if (event.key === 'ArrowLeft') next = (at - 1 + tabs.length) % tabs.length;
    else if (event.key === 'Home') next = 0;
    else if (event.key === 'End') next = tabs.length - 1;
    if (next < 0) return;
    event.preventDefault();
    tabs[next].focus();
    activate(tabs[next]);
  });
}

// --- new site (admin) ------------------------------------------------------

function openSiteDialog() {
  const list = $('site-buildings');
  list.replaceChildren();
  if (!state.buildings.length) {
    list.append(el('p', { class: 'empty-note', text: 'There are no buildings yet. Add one in the phone app first.' }));
  }
  for (const building of state.buildings) {
    const input = el('input', { attrs: { type: 'checkbox', name: 'site-building', value: building.id } });
    list.append(
      el(
        'label',
        { class: 'choice check' },
        input,
        el('span', { class: 'choice-body' }, el('span', {}, el('span', { class: 'choice-title', text: building.name }))),
      ),
    );
  }
  $('site-name').value = '';
  $('site-name').setAttribute('aria-invalid', 'false');
  $('site-error').hidden = true;
  $('site-dialog').showModal();
  $('site-name').focus();
}

async function createSite(event) {
  event.preventDefault();
  const name = $('site-name').value.trim();
  const error = $('site-error');
  if (!name) {
    error.textContent = 'Give the site a name.';
    error.hidden = false;
    $('site-name').setAttribute('aria-invalid', 'true');
    $('site-name').focus();
    return;
  }
  const ids = [...document.querySelectorAll('input[name="site-building"]:checked')].map((box) => box.value);
  const button = $('site-create');
  button.disabled = true;
  button.textContent = 'Creating…';
  try {
    const site = await api('/sites', { method: 'POST', json: { name, building_ids: ids } });
    $('site-dialog').close();
    await loadLists();
    state.siteId = site.id;
    state.buildingId = '';
    resetMerge();
    renderScope();
    writeHash();
    toast(`Created ${site.name}.`);
  } catch (failure) {
    error.textContent = explain(failure);
    error.hidden = false;
  } finally {
    button.disabled = false;
    button.textContent = 'Create site';
  }
}

// --- wiring ----------------------------------------------------------------

function wire() {
  map = new MapViewClass($('map'), { onHover, onScale });

  $('login-form').addEventListener('submit', signIn);
  $('toggle-password').addEventListener('click', () => {
    const show = $('password').type === 'password';
    $('password').type = show ? 'text' : 'password';
    $('toggle-password').textContent = show ? 'Hide' : 'Show';
    $('toggle-password').setAttribute('aria-pressed', show ? 'true' : 'false');
  });
  $('sign-out').addEventListener('click', () => {
    endSession('');
    history.replaceState(null, '', location.pathname);
  });

  for (const radio of document.querySelectorAll('input[name="mode"]')) {
    radio.addEventListener('change', () => {
      state.mode = radio.value;
      if (state.mode === 'campus' && !state.siteId) state.siteId = state.sites[0]?.id || '';
      resetMerge();
      renderScope();
      const data = currentData();
      if (data) {
        render(data);
      } else if (state.mode === 'survey' && state.surveyId) {
        loadSurvey();
      } else {
        showEmpty();
      }
      writeHash();
    });
  }
  $('site').addEventListener('change', () => {
    state.siteId = $('site').value;
    state.buildingId = '';
    resetMerge();
    renderScope();
    if (state.mode === 'campus') {
      state.loaded.campus = null;
      showEmpty();
    }
    writeHash();
  });
  $('building').addEventListener('change', () => {
    state.buildingId = $('building').value;
    renderSurveyList();
    writeHash();
  });
  $('merge-all').addEventListener('click', () => setMerge(true));
  $('merge-none').addEventListener('click', () => setMerge(false));
  $('merge').addEventListener('click', loadCampus);
  $('new-site').addEventListener('click', openSiteDialog);
  $('site-form').addEventListener('submit', createSite);
  $('site-cancel').addEventListener('click', () => $('site-dialog').close());

  $('view-tabs').addEventListener('click', (event) => {
    const tab = event.target.closest('.tab');
    if (tab && !tab.disabled) setView(tab.dataset.view);
  });
  wireTabs($('view-tabs'), (tab) => setView(tab.dataset.view));
  $('inspector-tabs').addEventListener('click', (event) => {
    const tab = event.target.closest('.tab');
    if (tab) setTab(tab.dataset.tab);
  });
  wireTabs($('inspector-tabs'), (tab) => setTab(tab.dataset.tab));

  $('network').addEventListener('change', () => {
    state.network = $('network').value;
    const data = currentData();
    if (data?.routers) {
      drawRouters(data);
      renderRoutersPanel(data);
    }
  });

  for (const [id, key] of [['show-good', 'good'], ['show-zones', 'zones'], ['show-routers', 'routers']]) {
    $(id).addEventListener('change', () => {
      state.layers[key] = $(id).checked;
      map.setLayers(state.layers);
      updateLegend();
    });
  }
  $('zoom-in').addEventListener('click', () => map.zoomBy(1.4));
  $('zoom-out').addEventListener('click', () => map.zoomBy(1 / 1.4));
  $('zoom-fit').addEventListener('click', () => map.fit());

  $('generate-report').addEventListener('click', generateReport);
  $('cancel-report').addEventListener('click', abortReport);
  $('copy-report').addEventListener('click', copyReport);
  $('export-report').addEventListener('click', downloadReport);

  window.addEventListener('hashchange', () => {
    if (token && location.hash !== currentHash()) applyHash(false);
  });
}

let MapViewClass = null;

async function main() {
  ({ MapView: MapViewClass } = await import('./mapview.mjs'));
  wire();
  await start();
}

if (typeof document !== 'undefined') main();

export { state };
