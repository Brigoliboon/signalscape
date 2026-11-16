// SignalScape 3D coverage page (FR-16, FR-17, FR-18).
//
// Opened in the app's WebView at /api/viewer/#survey=<id>&token=<jwt>, or started
// with window.signalscapeViewer.start({ surveyId, token }). It reads the finished
// survey from the normal API (summary, coverage, access points, networks, trail) with that
// bearer token and draws the floors stacked, each with its heatmap.
//
// All text from the API (SSIDs and so on) is written with textContent or drawn on a
// canvas, never as HTML.

import * as THREE from './vendor/three.module.js';
import { OrbitControls } from './vendor/OrbitControls.js';
import {
  CONFIDENCE_NOTE,
  LEVEL_COLORS,
  LEVEL_NAMES,
  cellLevels,
  dataExtent,
  fadedColor,
  floorElevation,
  formatDbm,
  isUuid,
  legendEntries,
  levelFor,
  networkLabel,
  parseFragment,
  toLocal,
} from './levels.mjs';
import {
  DEFAULT_CONTOUR_STEP_DB,
  LEGEND_TICKS,
  PAD_CELLS,
  RAMP_STOPS,
  RAMP_STRONG_DBM,
  RAMP_WEAK_DBM,
  cellAtPadded,
  contourSegments,
  dbmText,
  rampFraction,
  renderPixels,
  upsampleGrid,
} from './heat.mjs';

const PAGE_SIZE = 100;
const MAX_PAGES = 10;
const AP_COLOR = '#1d4ed8';
const TRAIL_COLOR = '#7c3aed';
const START_COLOR = '#16a34a';
const END_COLOR = '#dc2626';
// Just above the heatmap, which sits at 0.05.
const TRAIL_Y = 0.25;
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
  showTrail: $('show-trail'),
  showDead: $('show-dead'),
  opacity: $('heat-opacity'),
  opacityText: $('heat-opacity-text'),
  minRssi: $('heat-min-rssi'),
  minRssiText: $('heat-min-rssi-text'),
  contours: $('heat-contours'),
  rampBar: $('ramp-bar'),
  rampTicks: $('ramp-ticks'),
};

const state = {
  token: null,
  surveyId: null,
  survey: null,
  thresholds: null,
  floors: [], // top floor first
  accessPoints: [],
  trail: null,
  bssid: '',
  generation: 0,
  // How the heatmap is drawn. Opacity only changes the material; the minimum signal
  // and the contour lines redraw the picture.
  heat: { opacity: 0.85, minRssi: RAMP_WEAK_DBM, contours: true },
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
    const area = floorExtent(floor);
    if (area) extent = Math.max(extent, area.width, area.depth);
  }
  return Math.min(3, Math.max(0.5, extent / 60));
}

/** The block of the floor that holds data, in metres: { west, south, width, depth }. */
function floorExtent(floor) {
  const { layout, baseGrid } = floor;
  if (!layout) return null;
  const block = baseGrid ? dataExtent(baseGrid.values, baseGrid.cols) : null;
  if (!block) return layout;
  const { cell } = layout;
  return {
    west: layout.west + block.col0 * cell,
    south: layout.south + block.row0 * cell,
    width: (block.col1 - block.col0 + 1) * cell,
    depth: (block.row1 - block.row0 + 1) * cell,
  };
}

/** A faint footprint of the cells that have data, instead of a solid rectangle. */
function addFootprint(floor) {
  const { layout, baseGrid } = floor;
  const cells = [];
  baseGrid.values.forEach((value, index) => {
    if (value !== null && value !== undefined) cells.push(index);
  });
  if (cells.length === 0) return;
  const geometry = new THREE.PlaneGeometry(layout.cell, layout.cell);
  geometry.rotateX(-Math.PI / 2);
  const mesh = new THREE.InstancedMesh(
    geometry,
    new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.3, side: THREE.DoubleSide }),
    cells.length,
  );
  const matrix = new THREE.Matrix4();
  cells.forEach((index, i) => {
    const col = index % baseGrid.cols;
    const row = Math.floor(index / baseGrid.cols);
    matrix.makeTranslation(
      layout.west + (col + 0.5) * layout.cell,
      0,
      -(layout.south + (row + 0.5) * layout.cell),
    );
    mesh.setMatrixAt(i, matrix);
  });
  mesh.instanceMatrix.needsUpdate = true;
  floor.group.add(mesh);
  floor.slab = mesh;
}

/** Rebuild everything drawn for one floor: footprint, heatmap, dead zones, markers. */
function buildFloor(floor) {
  disposeGroup(floor.group);
  floor.heat = null;
  floor.field = null;
  floor.slab = null;
  floor.deadMesh = null;
  floor.apMeshes = [];
  floor.trailMeshes = [];
  floor.group.position.y = floorElevation(floor.info.floor_level, floor.info.floor_height_m);
  const unit = worldUnit();

  const { layout } = floor;
  if (layout) {
    if (floor.baseGrid) addFootprint(floor);
    const extent = floorExtent(floor);
    const label = makeLabel(`${floor.info.floor_label} (level ${floor.info.floor_level})`);
    const labelHeight = unit * 3;
    label.scale.set(labelHeight * label.userData.aspect, labelHeight, 1);
    label.position.set(
      extent.west + (labelHeight * label.userData.aspect) / 2,
      unit * 1.5,
      -extent.south + labelHeight / 2,
    );
    floor.group.add(label);

    if (floor.grid) addHeatmap(floor, floor.grid);
    addAccessPoints(floor, unit);
  }
  addTrail(floor, unit);
  applyVisibility(floor);
}

/**
 * The picture of one floor: the grid upsampled into a smooth field, coloured with the
 * rainbow ramp, with contour lines every few dB drawn on top. It is a canvas texture
 * with linear filtering. Cells without data stay transparent and the edge fades out.
 */
function makeHeatTexture(floor) {
  const grid = floor.grid;
  // The upsampled field depends only on the grid, so it is kept across slider moves.
  if (!floor.field) {
    floor.field = upsampleGrid({
      values: grid.values,
      confidence: grid.confidence,
      cols: grid.cols,
      rows: grid.rows,
    });
  }
  const field = floor.field;
  const canvas = document.createElement('canvas');
  canvas.width = field.width;
  canvas.height = field.height;
  const context = canvas.getContext('2d');
  const { minRssi, contours } = state.heat;
  context.putImageData(new ImageData(renderPixels(field, { minRssi }), field.width, field.height), 0, 0);
  if (contours) {
    const lines = contourSegments(field, { step: DEFAULT_CONTOUR_STEP_DB, minRssi });
    context.strokeStyle = 'rgba(0, 0, 0, 0.8)';
    context.lineWidth = Math.max(1.2, field.factor * 0.25);
    context.lineCap = 'round';
    context.beginPath();
    for (let i = 0; i < lines.length; i += 4) {
      context.moveTo(lines[i], lines[i + 1]);
      context.lineTo(lines[i + 2], lines[i + 3]);
    }
    context.stroke();
  }
  const texture = new THREE.CanvasTexture(canvas);
  texture.magFilter = THREE.LinearFilter;
  texture.minFilter = THREE.LinearMipmapLinearFilter;
  texture.generateMipmaps = true;
  texture.anisotropy = renderer ? Math.min(8, renderer.capabilities.getMaxAnisotropy()) : 1;
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.needsUpdate = true;
  return texture;
}

/** Redraw the heat pictures after the minimum signal or the contour toggle changed. */
function refreshHeat() {
  for (const floor of state.floors) {
    if (!floor.heat) continue;
    const old = floor.heat.material.map;
    floor.heat.material.map = makeHeatTexture(floor);
    floor.heat.material.needsUpdate = true;
    if (old) old.dispose();
  }
  requestRender();
}

function addHeatmap(floor, grid) {
  const layout = gridLayout(grid);
  const levels = cellLevels(grid.values, state.thresholds);
  // The picture has a blank cell all around, so it is a little larger than the grid.
  const pad = PAD_CELLS * layout.cell;
  const heat = new THREE.Mesh(
    new THREE.PlaneGeometry(layout.width + 2 * pad, layout.depth + 2 * pad),
    new THREE.MeshBasicMaterial({
      map: makeHeatTexture(floor),
      transparent: true,
      opacity: state.heat.opacity,
      depthWrite: false,
      side: THREE.DoubleSide,
    }),
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

/** A marker on a pole with a label: the start or the end of the walk. */
function addEndMarker(floor, point, text, color, shape, unit) {
  const marker = new THREE.Group();
  const material = new THREE.MeshLambertMaterial({ color });
  const body = new THREE.Mesh(
    shape === 'cone' ? new THREE.ConeGeometry(unit * 1.1, unit * 2.2, 16) : new THREE.SphereGeometry(unit * 1.1, 16, 12),
    material,
  );
  body.position.y = unit * 3.2;
  if (shape === 'cone') body.rotation.x = Math.PI; // point down at the spot
  const pole = new THREE.Mesh(
    new THREE.CylinderGeometry(unit * 0.08, unit * 0.08, unit * 3, 6),
    new THREE.MeshBasicMaterial({ color }),
  );
  pole.position.y = unit * 1.5;
  const name = makeLabel(text, color);
  const nameHeight = unit * 2.6;
  name.scale.set(nameHeight * name.userData.aspect, nameHeight, 1);
  name.position.y = unit * 6;
  marker.add(body, pole, name);
  marker.position.set(point.x, TRAIL_Y, point.z);
  floor.group.add(marker);
  floor.trailMeshes.push(marker);
}

/** The walked path of one floor: a line, a dot at every scan, a start and an end. */
function addTrail(floor, unit) {
  const points = floor.trailPoints;
  if (!points || points.length === 0) return;
  const dots = points.filter((p) => p.kind !== 'start');
  if (points.length > 1) {
    const line = new THREE.Line(
      new THREE.BufferGeometry().setFromPoints(points.map((p) => new THREE.Vector3(p.x, TRAIL_Y, p.z))),
      new THREE.LineBasicMaterial({ color: TRAIL_COLOR }),
    );
    floor.group.add(line);
    floor.trailMeshes.push(line);
  }
  if (dots.length > 0) {
    const mesh = new THREE.InstancedMesh(
      new THREE.SphereGeometry(unit * 0.4, 8, 6),
      new THREE.MeshBasicMaterial({ color: TRAIL_COLOR }),
      dots.length,
    );
    const matrix = new THREE.Matrix4();
    dots.forEach((p, i) => {
      matrix.makeTranslation(p.x, TRAIL_Y, p.z);
      mesh.setMatrixAt(i, matrix);
    });
    mesh.instanceMatrix.needsUpdate = true;
    floor.group.add(mesh);
    floor.trailMeshes.push(mesh);
  }
  const { start, end } = state.trail;
  if (start && start.floor_id === floor.info.floor_id) {
    addEndMarker(floor, points[0], 'Start', START_COLOR, 'sphere', unit);
  }
  if (end && end.floor_id === floor.info.floor_id) {
    addEndMarker(floor, points[points.length - 1], 'End', END_COLOR, 'cone', unit);
  }
}

/** Trail points of a floor as scene positions (x east, z south). */
function trailPointsOf(floor) {
  const trailFloor = state.trail && state.trail.floors.find((f) => f.floor_id === floor.info.floor_id);
  if (!trailFloor) return [];
  return trailFloor.points.map((p) => {
    const local = toLocal(p.lat, p.lng, state.survey.origin_lat, state.survey.origin_lng);
    return { x: local.x, z: -local.y, kind: p.kind };
  });
}

function applyVisibility(floor) {
  for (const object of floor.trailMeshes || []) object.visible = els.showTrail.checked;
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
    const y = floor.group.position.y;
    const extent = floorExtent(floor);
    if (extent) {
      const { west, south, width, depth } = extent;
      box.expandByPoint(new THREE.Vector3(west, y, -(south + depth)));
      box.expandByPoint(new THREE.Vector3(west + width, y + 4, -south));
    }
    for (const p of floor.trailPoints || []) box.expandByPoint(new THREE.Vector3(p.x, y, p.z));
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
  // The nearest grid cell: the picture is smooth, the numbers are the cells' own.
  const { index } = cellAtPadded(hit.uv.x, hit.uv.y, floor.grid.cols, floor.grid.rows);
  const value = floor.grid.values[index];
  if (value === null || value === undefined) {
    showInfo(`${floor.info.floor_label}: no data here (no reading within 5 m)`);
    return;
  }
  const level = levelFor(value, state.thresholds.good_dbm, state.thresholds.dead_dbm);
  showInfo(`${floor.info.floor_label}: ${formatDbm(value)} · ${LEVEL_NAMES[level]}`);
}

// --- controls ----------------------------------------------------------------

/** The ramp as a gradient bar (strong on the left) with dBm ticks under it. */
function buildRampBar() {
  const canvas = els.rampBar;
  const context = canvas.getContext('2d');
  const gradient = context.createLinearGradient(0, 0, canvas.width, 0);
  for (const stop of RAMP_STOPS) gradient.addColorStop(rampFraction(stop.dbm), stop.color);
  context.fillStyle = gradient;
  context.fillRect(0, 0, canvas.width, canvas.height);
  els.rampTicks.replaceChildren();
  for (const dbm of LEGEND_TICKS) {
    const tick = document.createElement('span');
    tick.textContent = String(dbm);
    tick.style.left = `${rampFraction(dbm) * 100}%`;
    els.rampTicks.append(tick);
  }
}

function buildLegend() {
  buildRampBar();
  els.legend.replaceChildren();
  // The map is a continuous ramp now; the thresholds stay as text, and only the dead
  // zone keeps a swatch because it is still marked with red blocks.
  const rows = legendEntries(state.thresholds).map((entry) => ({
    text: entry.text,
    color: entry.level === 'dead' ? entry.color : null,
  }));
  rows.push({ text: `Lines: every ${DEFAULT_CONTOUR_STEP_DB} dBm`, color: null });
  rows.push({ text: CONFIDENCE_NOTE, color: fadedColor(LEVEL_COLORS.fair) });
  rows.push({ text: 'Estimated access point', color: AP_COLOR, ap: true });
  if (state.trail && state.trail.start) {
    rows.push({ text: 'Walked path', color: TRAIL_COLOR });
    rows.push({ text: 'Start', color: START_COLOR });
    rows.push({ text: 'End', color: END_COLOR });
  }
  for (const row of rows) {
    const item = document.createElement('li');
    const swatch = document.createElement('span');
    swatch.className = row.ap ? 'swatch ap' : 'swatch';
    if (row.color) swatch.style.background = row.color;
    else swatch.classList.add('none');
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
els.showTrail.addEventListener('change', applyAllVisibility);
els.showDead.addEventListener('change', applyAllVisibility);

function showHeatSettings() {
  els.opacityText.textContent = `${state.heat.opacity * 100}%`;
  els.minRssiText.textContent = dbmText(state.heat.minRssi);
}

els.opacity.addEventListener('input', () => {
  state.heat.opacity = Number(els.opacity.value) / 100;
  for (const floor of state.floors) {
    if (floor.heat) floor.heat.material.opacity = state.heat.opacity;
  }
  showHeatSettings();
  requestRender();
});
// The picture is made again at most once per pause: dragging the slider on a big floor
// would otherwise redraw a multi-megapixel texture on every tick.
let heatTimer = null;
function scheduleHeat(delayMs) {
  if (heatTimer !== null) clearTimeout(heatTimer);
  heatTimer = setTimeout(() => {
    heatTimer = null;
    refreshHeat();
  }, delayMs);
}
els.minRssi.addEventListener('input', () => {
  state.heat.minRssi = Number(els.minRssi.value);
  showHeatSettings(); // the number follows the thumb at once
  scheduleHeat(150);
});
els.minRssi.addEventListener('change', () => scheduleHeat(0));
els.contours.addEventListener('change', () => {
  state.heat.contours = els.contours.checked;
  refreshHeat();
});
els.opacity.value = String(Math.round(state.heat.opacity * 100));
els.minRssi.min = String(RAMP_WEAK_DBM);
els.minRssi.max = String(RAMP_STRONG_DBM);
els.minRssi.value = String(state.heat.minRssi);
els.contours.checked = state.heat.contours;
showHeatSettings();
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
  Object.assign(state, { token, surveyId, bssid: '', survey: null, accessPoints: [], trail: null, floors: [] });
  els.info.hidden = true;
  showStatus('Loading coverage…');
  try {
    const [survey, summary] = await Promise.all([
      api(`/surveys/${surveyId}`),
      api(`/surveys/${surveyId}/summary`),
    ]);
    const [networks, accessPoints, trail] = await Promise.all([
      allPages(`/surveys/${surveyId}/networks?sort=-reading_count`),
      allPages(`/surveys/${surveyId}/access-points`),
      // The coverage still shows if the walk cannot be loaded.
      api(`/surveys/${surveyId}/trail`).catch(() => null),
    ]);
    const floors = [...summary.floors]
      .sort((a, b) => b.floor_level - a.floor_level)
      .map((info) => ({
        info,
        visible: true,
        grid: null,
        baseGrid: null,
        layout: null,
        trailPoints: [],
        group: new THREE.Group(),
      }));
    state.survey = survey;
    await Promise.all(
      floors.map(async (floor) => {
        floor.grid = await loadGrid(floor, null);
        floor.baseGrid = floor.grid;
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
    state.trail = trail;
    for (const floor of floors) floor.trailPoints = trailPointsOf(floor);

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
