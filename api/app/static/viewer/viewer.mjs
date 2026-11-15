// SignalScape 3D coverage page (FR-16, FR-17, FR-18).
//
// Opened in the app's WebView at /api/viewer/#survey=<id>&token=<jwt>, or started
// with window.signalscapeViewer.start({ surveyId, token }). It reads the finished
// survey from the normal API (summary, coverage, access points, networks) with that
// bearer token and draws the floors stacked, each with its heatmap.
//
// All text from the API (SSIDs and so on) is written with textContent or drawn on a
// canvas, never as HTML.

import * as THREE from './vendor/three.module.js';
import { OrbitControls } from './vendor/OrbitControls.js';
import {
  LEVEL_COLORS,
  LEVEL_NAMES,
  cellAt,
  cellLevels,
  cellPixels,
  floorElevation,
  formatDbm,
  isUuid,
  legendEntries,
  levelFor,
  networkLabel,
  parseFragment,
  toLocal,
} from './levels.mjs';

const PAGE_SIZE = 100;
const MAX_PAGES = 10;
const AP_COLOR = '#1d4ed8';
const TAP_MOVE_PX = 8;

const $ = (id) => document.getElementById(id);
const els = {
  canvas: $('scene'),
  status: $('status'),
  info: $('info'),
  legend: $('legend-list'),
  layersToggle: $('layers-toggle'),
  layers: $('layers'),
  network: $('network'),
  floorList: $('floor-list'),
  showAps: $('show-aps'),
  showDead: $('show-dead'),
};

const state = {
  token: null,
  surveyId: null,
  survey: null,
  thresholds: null,
  floors: [], // top floor first
  accessPoints: [],
  bssid: '',
  generation: 0,
};

let renderer = null;
let scene = null;
let camera = null;
let controls = null;
let root = null;
let renderQueued = false;
const raycaster = new THREE.Raycaster();

// --- API ---------------------------------------------------------------------

class ApiError extends Error {
  constructor(status) {
    super(`HTTP ${status}`);
    this.status = status;
  }
}

async function api(path) {
  const response = await fetch(`/api${path}`, {
    headers: { Authorization: `Bearer ${state.token}`, Accept: 'application/json' },
    cache: 'no-store',
    referrerPolicy: 'no-referrer',
  });
  if (!response.ok) throw new ApiError(response.status);
  return response.json();
}

async function allPages(path) {
  const joiner = path.includes('?') ? '&' : '?';
  const items = [];
  for (let page = 1; page <= MAX_PAGES; page += 1) {
    const data = await api(`${path}${joiner}page=${page}&page_size=${PAGE_SIZE}`);
    items.push(...data.items);
    if (items.length >= data.total || data.items.length === 0) break;
  }
  return items;
}

function errorText(error) {
  if (error instanceof ApiError) {
    if (error.status === 401) return 'Your session has expired. Close this view and open it again.';
    if (error.status === 404) return "This survey was not found, or it isn't shared with you.";
    if (error.status === 409) return "This survey hasn't been processed yet. Complete it and process it first.";
    return `Could not load the coverage (error ${error.status}).`;
  }
  if (error instanceof TypeError) return 'Could not reach the server. Check your connection.';
  return 'Something went wrong while drawing the coverage.';
}

/** The grid of one floor for the chosen network, or null if there is none. */
async function loadGrid(floor, bssid) {
  if (floor.info.cleaned_reading_count === 0) return null;
  const query = bssid ? `&bssid=${encodeURIComponent(bssid)}` : '';
  try {
    return await api(`/surveys/${state.surveyId}/coverage?floor_id=${floor.info.floor_id}${query}`);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) return null;
    throw error;
  }
}

// --- messages ----------------------------------------------------------------

function showStatus(text, isError = false) {
  els.status.textContent = text;
  els.status.classList.toggle('error', isError);
  els.status.hidden = false;
}

function hideStatus() {
  els.status.hidden = true;
}

function showInfo(text) {
  els.info.textContent = text;
  els.info.hidden = false;
}

// --- three.js scene ----------------------------------------------------------

function ensureRenderer() {
  if (renderer) return;
  renderer = new THREE.WebGLRenderer({ canvas: els.canvas, antialias: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.setClearColor(0xeef2f7, 1);
  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(50, 1, 0.1, 5000);
  scene.add(new THREE.AmbientLight(0xffffff, 1.6));
  const sun = new THREE.DirectionalLight(0xffffff, 1.4);
  sun.position.set(30, 80, 40);
  scene.add(sun);
  root = new THREE.Group();
  scene.add(root);

  controls = new OrbitControls(camera, els.canvas);
  controls.screenSpacePanning = true;
  controls.maxPolarAngle = Math.PI * 0.495;
  controls.addEventListener('change', requestRender);

  new ResizeObserver(resize).observe(els.canvas);
  window.addEventListener('resize', resize);
  watchTaps();
  resize();
}

function resize() {
  if (!renderer) return;
  const width = Math.max(1, els.canvas.clientWidth);
  const height = Math.max(1, els.canvas.clientHeight);
  renderer.setSize(width, height, false);
  camera.aspect = width / height;
  // Shift the picture up a little so the layers sheet leaves more of it in view.
  camera.setViewOffset(width, height, 0, height * 0.1, width, height);
  camera.updateProjectionMatrix();
  requestRender();
}

function requestRender() {
  if (renderQueued || !renderer) return;
  renderQueued = true;
  requestAnimationFrame(() => {
    renderQueued = false;
    controls.update();
    renderer.render(scene, camera);
  });
}

function disposeGroup(group) {
  group.traverse((object) => {
    if (object.geometry) object.geometry.dispose();
    const materials = Array.isArray(object.material) ? object.material : [object.material];
    for (const material of materials) {
      if (!material) continue;
      if (material.map) material.map.dispose();
      material.dispose();
    }
  });
  group.clear();
}

function makeLabel(text, color = '#111827') {
  const canvas = document.createElement('canvas');
  const context = canvas.getContext('2d');
  const font = '600 44px system-ui, sans-serif';
  context.font = font;
  const width = Math.ceil(context.measureText(text).width) + 32;
  canvas.width = width;
  canvas.height = 72;
  context.font = font;
  context.fillStyle = 'rgba(255,255,255,0.88)';
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = color;
  context.textBaseline = 'middle';
  context.fillText(text, 16, 38);
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  const sprite = new THREE.Sprite(
    new THREE.SpriteMaterial({ map: texture, depthTest: false, transparent: true }),
  );
  sprite.userData.aspect = canvas.width / canvas.height;
  sprite.renderOrder = 10;
  return sprite;
}

function gridLayout(grid) {
  const origin = toLocal(grid.origin_lat, grid.origin_lng, state.survey.origin_lat, state.survey.origin_lng);
  const cell = grid.cell_size_m;
  const width = grid.cols * cell;
  const depth = grid.rows * cell;
  return {
    cell,
    width,
    depth,
    west: origin.x,
    south: origin.y,
    centerX: origin.x + width / 2,
    centerZ: -(origin.y + depth / 2), // north is -z
  };
}

function worldUnit() {
  let extent = 20;
  for (const floor of state.floors) {
    if (floor.layout) extent = Math.max(extent, floor.layout.width, floor.layout.depth);
  }
  return Math.min(3, Math.max(0.5, extent / 60));
}

/** Rebuild everything drawn for one floor: slab, heatmap, dead zones, markers. */
function buildFloor(floor) {
  disposeGroup(floor.group);
  floor.heat = null;
  floor.slab = null;
  floor.deadMesh = null;
  floor.apMeshes = [];
  floor.group.position.y = floorElevation(floor.info.floor_level, floor.info.floor_height_m);
  if (!floor.layout) return;

  const { layout } = floor;
  const unit = worldUnit();

  const slab = new THREE.Mesh(
    new THREE.PlaneGeometry(layout.width, layout.depth),
    new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.55, side: THREE.DoubleSide }),
  );
  slab.rotation.x = -Math.PI / 2;
  slab.position.set(layout.centerX, 0, layout.centerZ);
  floor.group.add(slab);
  floor.slab = slab;
  const outline = new THREE.LineSegments(
    new THREE.EdgesGeometry(slab.geometry),
    new THREE.LineBasicMaterial({ color: 0x6b7280 }),
  );
  outline.rotation.copy(slab.rotation);
  outline.position.copy(slab.position);
  floor.group.add(outline);

  const label = makeLabel(`${floor.info.floor_label} (level ${floor.info.floor_level})`);
  const labelHeight = unit * 3;
  label.scale.set(labelHeight * label.userData.aspect, labelHeight, 1);
  label.position.set(layout.west + (labelHeight * label.userData.aspect) / 2, unit * 1.5, layout.centerZ + layout.depth / 2 + labelHeight / 2);
  floor.group.add(label);

  if (floor.grid) addHeatmap(floor, floor.grid);
  addAccessPoints(floor, unit);
  applyVisibility(floor);
}

function addHeatmap(floor, grid) {
  const layout = gridLayout(grid);
  const levels = cellLevels(grid.values, state.thresholds);
  const texture = new THREE.DataTexture(cellPixels(levels), grid.cols, grid.rows, THREE.RGBAFormat);
  texture.magFilter = THREE.NearestFilter;
  texture.minFilter = THREE.NearestFilter;
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.needsUpdate = true;

  const heat = new THREE.Mesh(
    new THREE.PlaneGeometry(layout.width, layout.depth),
    new THREE.MeshBasicMaterial({ map: texture, transparent: true, depthWrite: false, side: THREE.DoubleSide }),
  );
  heat.rotation.x = -Math.PI / 2;
  heat.position.set(layout.centerX, 0.05, layout.centerZ);
  heat.userData.layout = layout;
  floor.group.add(heat);
  floor.heat = heat;

  const dead = [];
  levels.forEach((level, index) => {
    if (level === 'dead') dead.push(index);
  });
  if (dead.length > 0) {
    const mesh = new THREE.InstancedMesh(
      new THREE.BoxGeometry(layout.cell * 0.9, 1, layout.cell * 0.9),
      new THREE.MeshLambertMaterial({ color: LEVEL_COLORS.dead, transparent: true, opacity: 0.6 }),
      dead.length,
    );
    const matrix = new THREE.Matrix4();
    const rise = Math.max(0.6, layout.cell * 0.8);
    dead.forEach((index, i) => {
      const col = index % grid.cols;
      const row = Math.floor(index / grid.cols);
      matrix.makeScale(1, rise, 1);
      matrix.setPosition(
        layout.west + (col + 0.5) * layout.cell,
        rise / 2,
        -(layout.south + (row + 0.5) * layout.cell),
      );
      mesh.setMatrixAt(i, matrix);
    });
    mesh.instanceMatrix.needsUpdate = true;
    floor.group.add(mesh);
    floor.deadMesh = mesh;
  }
}

function addAccessPoints(floor, unit) {
  for (const ap of state.accessPoints) {
    if (ap.floor_id !== floor.info.floor_id) continue;
    const local = toLocal(ap.lat, ap.lng, state.survey.origin_lat, state.survey.origin_lng);
    const marker = new THREE.Group();
    const body = new THREE.Mesh(
      new THREE.OctahedronGeometry(unit * 1.3),
      new THREE.MeshLambertMaterial({ color: AP_COLOR }),
    );
    body.position.y = unit * 3;
    const pole = new THREE.Mesh(
      new THREE.CylinderGeometry(unit * 0.08, unit * 0.08, unit * 3, 6),
      new THREE.MeshBasicMaterial({ color: AP_COLOR }),
    );
    pole.position.y = unit * 1.5;
    const name = makeLabel(ap.ssid && ap.ssid.length > 0 ? ap.ssid : '(hidden)', AP_COLOR);
    const nameHeight = unit * 2.6;
    name.scale.set(nameHeight * name.userData.aspect, nameHeight, 1);
    name.position.y = unit * 5.8;
    marker.add(body, pole, name);
    marker.position.set(local.x, 0, -local.y);
    body.userData.accessPoint = ap;
    floor.group.add(marker);
    floor.apMeshes.push({ marker, body, ap });
  }
}

function applyVisibility(floor) {
  floor.group.visible = floor.visible;
  if (floor.deadMesh) floor.deadMesh.visible = els.showDead.checked;
  for (const item of floor.apMeshes) {
    item.marker.visible = els.showAps.checked && (!state.bssid || item.ap.bssid === state.bssid);
  }
}

function applyAllVisibility() {
  state.floors.forEach(applyVisibility);
  requestRender();
}

function frameScene() {
  const box = new THREE.Box3();
  for (const floor of state.floors) {
    if (!floor.layout) continue;
    const y = floor.group.position.y;
    const { west, south, width, depth } = floor.layout;
    box.expandByPoint(new THREE.Vector3(west, y, -(south + depth)));
    box.expandByPoint(new THREE.Vector3(west + width, y + 4, -south));
  }
  if (box.isEmpty()) return;
  const center = box.getCenter(new THREE.Vector3());
  const radius = Math.max(box.getSize(new THREE.Vector3()).length() / 2, 5);
  const vfov = (camera.fov * Math.PI) / 180;
  const hfov = 2 * Math.atan(Math.tan(vfov / 2) * camera.aspect);
  const distance = (radius / Math.tan(Math.min(vfov, hfov) / 2)) * 1.15;
  const direction = new THREE.Vector3(0.7, 0.8, 1.1).normalize();
  camera.position.copy(center).addScaledVector(direction, distance);
  camera.far = distance * 10;
  camera.updateProjectionMatrix();
  controls.target.copy(center);
  controls.minDistance = radius * 0.3;
  controls.maxDistance = distance * 3;
  controls.update();
}

// --- tapping a cell or an access point ----------------------------------------

function watchTaps() {
  let down = null;
  els.canvas.addEventListener('pointerdown', (event) => {
    down = { x: event.clientX, y: event.clientY, id: event.pointerId };
  });
  els.canvas.addEventListener('pointerup', (event) => {
    if (!down || down.id !== event.pointerId) return;
    const moved = Math.hypot(event.clientX - down.x, event.clientY - down.y);
    down = null;
    if (moved <= TAP_MOVE_PX) pick(event);
  });
  els.canvas.addEventListener('pointercancel', () => {
    down = null;
  });
}

function pick(event) {
  const rect = els.canvas.getBoundingClientRect();
  raycaster.setFromCamera(
    new THREE.Vector2(
      ((event.clientX - rect.left) / rect.width) * 2 - 1,
      -((event.clientY - rect.top) / rect.height) * 2 + 1,
    ),
    camera,
  );
  const targets = [];
  for (const floor of state.floors) {
    if (!floor.visible) continue;
    const surface = floor.heat || floor.slab;
    if (surface) targets.push(surface);
    for (const item of floor.apMeshes) {
      if (item.marker.visible) targets.push(item.body);
    }
  }
  const hit = raycaster.intersectObjects(targets, false)[0];
  if (!hit) {
    els.info.hidden = true;
    return;
  }
  const ap = hit.object.userData.accessPoint;
  if (ap) {
    const name = ap.ssid && ap.ssid.length > 0 ? ap.ssid : '(hidden network)';
    showInfo(
      `Estimated access point: ${name} · ${ap.bssid} · strongest reading ${formatDbm(ap.max_rssi_dbm)}, ` +
        `placed from ${ap.reading_count} readings`,
    );
  } else {
    describeCell(hit);
  }
  requestRender();
}

function describeCell(hit) {
  const floor = state.floors.find((f) => f.heat === hit.object || f.slab === hit.object);
  if (!floor) return;
  if (!floor.grid || floor.heat !== hit.object) {
    showInfo(`${floor.info.floor_label}: no readings of this network on this floor`);
    return;
  }
  const { index } = cellAt(hit.uv.x, hit.uv.y, floor.grid.cols, floor.grid.rows);
  const value = floor.grid.values[index];
  if (value === null || value === undefined) {
    showInfo(`${floor.info.floor_label}: no data here (no reading within 10 m)`);
    return;
  }
  const level = levelFor(value, state.thresholds.good_dbm, state.thresholds.dead_dbm);
  showInfo(`${floor.info.floor_label}: ${formatDbm(value)} · ${LEVEL_NAMES[level]}`);
}

// --- controls ----------------------------------------------------------------

function buildLegend() {
  els.legend.replaceChildren();
  const rows = legendEntries(state.thresholds).map((entry) => ({ text: entry.text, color: entry.color }));
  rows.push({ text: 'Estimated access point', color: AP_COLOR, ap: true });
  for (const row of rows) {
    const item = document.createElement('li');
    const swatch = document.createElement('span');
    swatch.className = row.ap ? 'swatch ap' : 'swatch';
    swatch.style.background = row.color;
    swatch.setAttribute('aria-hidden', 'true');
    const text = document.createElement('span');
    text.textContent = row.text;
    item.append(swatch, text);
    els.legend.append(item);
  }
}

function floorSummaryText(floor) {
  if (!floor.layout) return 'No usable readings';
  if (!floor.grid) return 'No readings of this network';
  return `Dead zone: ${Math.round(floor.grid.dead_pct)}% of the covered area`;
}

function buildFloorList() {
  els.floorList.replaceChildren();
  for (const floor of state.floors) {
    const label = document.createElement('label');
    label.className = 'check';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.checked = floor.visible;
    box.addEventListener('change', () => {
      floor.visible = box.checked;
      applyVisibility(floor);
      requestRender();
    });
    const text = document.createElement('span');
    text.textContent = `${floor.info.floor_label} (level ${floor.info.floor_level})`;
    const small = document.createElement('small');
    floor.summaryEl = small;
    small.textContent = floorSummaryText(floor);
    text.append(small);
    label.append(box, text);
    els.floorList.append(label);
  }
}

function buildNetworkList(networks) {
  els.network.replaceChildren();
  const all = document.createElement('option');
  all.value = '';
  all.textContent = 'All networks (strongest signal)';
  els.network.append(all);
  const seen = new Set();
  for (const network of networks) {
    if (seen.has(network.bssid)) continue;
    seen.add(network.bssid);
    const option = document.createElement('option');
    option.value = network.bssid;
    option.textContent = networkLabel(network);
    els.network.append(option);
  }
}

async function changeNetwork() {
  const generation = state.generation;
  state.bssid = els.network.value;
  els.network.disabled = true;
  showStatus('Loading network…');
  try {
    const grids = await Promise.all(state.floors.map((floor) => loadGrid(floor, state.bssid)));
    if (generation !== state.generation) return;
    state.floors.forEach((floor, i) => {
      floor.grid = grids[i];
      buildFloor(floor);
      if (floor.summaryEl) floor.summaryEl.textContent = floorSummaryText(floor);
    });
    hideStatus();
    els.info.hidden = true;
    requestRender();
  } catch (error) {
    showStatus(errorText(error), true);
  } finally {
    els.network.disabled = false;
  }
}

els.network.addEventListener('change', changeNetwork);
els.showAps.addEventListener('change', applyAllVisibility);
els.showDead.addEventListener('change', applyAllVisibility);
els.layersToggle.addEventListener('click', () => {
  const open = els.layers.hidden;
  els.layers.hidden = !open;
  els.layersToggle.setAttribute('aria-expanded', String(open));
  document.body.classList.toggle('sheet-open', open);
});

// --- start -------------------------------------------------------------------

async function start({ surveyId, token }) {
  if (!isUuid(surveyId) || !token) {
    showStatus('This view needs a survey and a sign-in from the app.', true);
    return;
  }
  state.generation += 1;
  const generation = state.generation;
  Object.assign(state, { token, surveyId, bssid: '', survey: null, accessPoints: [], floors: [] });
  els.info.hidden = true;
  showStatus('Loading coverage…');
  try {
    const [survey, summary] = await Promise.all([
      api(`/surveys/${surveyId}`),
      api(`/surveys/${surveyId}/summary`),
    ]);
    const [networks, accessPoints] = await Promise.all([
      allPages(`/surveys/${surveyId}/networks?sort=-reading_count`),
      allPages(`/surveys/${surveyId}/access-points`),
    ]);
    const floors = [...summary.floors]
      .sort((a, b) => b.floor_level - a.floor_level)
      .map((info) => ({ info, visible: true, grid: null, layout: null, group: new THREE.Group() }));
    state.survey = survey;
    await Promise.all(
      floors.map(async (floor) => {
        floor.grid = await loadGrid(floor, null);
        floor.layout = floor.grid ? gridLayout(floor.grid) : null;
      }),
    );
    if (generation !== state.generation) return;
    const withData = floors.find((floor) => floor.grid);
    state.thresholds = withData
      ? withData.grid.thresholds
      : summary.floors.map((f) => f.thresholds).find(Boolean);
    if (!state.thresholds) {
      showStatus('This survey has no usable readings to show.', true);
      return;
    }
    state.floors = floors;
    state.accessPoints = accessPoints;

    ensureRenderer();
    root.children.slice().forEach((child) => {
      disposeGroup(child);
      root.remove(child);
    });
    buildLegend();
    buildNetworkList(networks);
    buildFloorList();
    for (const floor of floors) {
      root.add(floor.group);
      buildFloor(floor);
    }
    resize();
    frameScene();
    hideStatus();
    requestRender();
  } catch (error) {
    if (generation === state.generation) showStatus(errorText(error), true);
  }
}

window.signalscapeViewer = { start };

const config = parseFragment(window.location.hash);
if (config) {
  // Drop the token from the address bar and history as soon as it is read.
  window.history.replaceState(null, '', window.location.pathname + window.location.search);
  start(config);
}
