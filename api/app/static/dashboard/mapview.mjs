// The 2D map of the SignalScape dashboard: a canvas you can drag, zoom and
// read. It draws a scene of cells, router pins and links in local metres (see
// lib.mjs) and reports what is under the pointer so the page can describe it.

import { boundsOf, findCell, LEVELS } from './lib.mjs';

const MIN_SCALE = 0.25;
const MAX_SCALE = 240;
const FIT_PAD = { top: 40, right: 40, bottom: 88, left: 40 };
const PIN_RADIUS = 9;
const LINK_STYLE = {
  covered: { color: '#60A5FA', dash: [], width: 2 },
  weak: { color: LEVELS.fair.color, dash: [9, 5], width: 2.5 },
  dead: { color: LEVELS.dead.color, dash: [2, 5], width: 3 },
  no_data: { color: '#9DB0CC', dash: [4, 6], width: 1.5 },
};

export class MapView {
  constructor(canvas, { onHover = () => {}, onScale = () => {} } = {}) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.onHover = onHover;
    this.onScale = onScale;
    this.scene = { cells: [], pins: [], lines: [] };
    this.floor = null;
    this.layers = { good: true, zones: true, routers: true };
    this.scale = 1;
    this.offsetX = 0;
    this.offsetY = 0;
    this.width = 0;
    this.height = 0;
    this.ratio = 1;
    this.frame = 0;
    this.drag = null;
    this.hasFit = false;
    this.moved = false;
    this.hatch = null;

    this.resizer = new ResizeObserver(() => this.resize());
    this.resizer.observe(canvas);
    canvas.addEventListener('pointerdown', (event) => this.pointerDown(event));
    canvas.addEventListener('pointermove', (event) => this.pointerMove(event));
    canvas.addEventListener('pointerup', (event) => this.pointerUp(event));
    canvas.addEventListener('pointercancel', (event) => this.pointerUp(event));
    canvas.addEventListener('pointerleave', () => this.onHover(null));
    canvas.addEventListener('wheel', (event) => this.wheel(event), { passive: false });
    canvas.addEventListener('dblclick', (event) => this.zoomAt(event, 1.8));
    canvas.addEventListener('keydown', (event) => this.keyDown(event));
    this.resize();
  }

  // --- scene ---------------------------------------------------------------

  setScene(scene, { refit = true } = {}) {
    this.scene = { cells: [], pins: [], lines: [], ...scene };
    if (refit || !this.hasFit) this.fit();
    else this.schedule();
  }

  setFloor(level) {
    this.floor = level;
    this.fit();
  }

  setLayers(layers) {
    this.layers = { ...this.layers, ...layers };
    this.schedule();
  }

  clear() {
    this.scene = { cells: [], pins: [], lines: [] };
    this.hasFit = false;
    this.schedule();
  }

  onFloor(item) {
    return this.floor == null || item.floor == null || item.floor === this.floor;
  }

  cellVisible(cell) {
    if (!this.onFloor(cell)) return false;
    return cell.level === 'good' ? this.layers.good : this.layers.zones;
  }

  visibleScene() {
    return {
      cells: this.scene.cells.filter((cell) => this.onFloor(cell)),
      pins: this.scene.pins.filter((pin) => this.onFloor(pin)),
      lines: this.scene.lines.filter((line) => this.onFloor(line)),
    };
  }

  // --- view ----------------------------------------------------------------

  // Read the size the canvas has right now. A canvas that was hidden reports
  // zero until the browser lays it out, so every fit measures first.
  measure() {
    const rect = this.canvas.getBoundingClientRect();
    const ratio = window.devicePixelRatio || 1;
    const width = Math.max(1, rect.width);
    const height = Math.max(1, rect.height);
    if (width === this.width && height === this.height && ratio === this.ratio) return false;
    this.ratio = ratio;
    this.width = width;
    this.height = height;
    this.canvas.width = Math.max(1, Math.round(width * ratio));
    this.canvas.height = Math.max(1, Math.round(height * ratio));
    this.hatch = null;
    return true;
  }

  // A resize keeps the framing the person chose. If they have not moved the
  // map since it was last fitted, it is fitted again to the new size.
  resize() {
    if (!this.measure()) return;
    if (this.hasFit && this.moved) this.schedule();
    else this.fit();
  }

  fit() {
    this.measure();
    this.moved = false;
    const box = boundsOf(this.visibleScene());
    if (!box) {
      this.hasFit = false;
      this.schedule();
      return;
    }
    const spanX = Math.max(box.x1 - box.x0, 1);
    const spanY = Math.max(box.y1 - box.y0, 1);
    const room = {
      w: this.width - FIT_PAD.left - FIT_PAD.right,
      h: this.height - FIT_PAD.top - FIT_PAD.bottom,
    };
    const scale = Math.min(room.w / spanX, room.h / spanY);
    this.scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale));
    const cx = (box.x0 + box.x1) / 2;
    const cy = (box.y0 + box.y1) / 2;
    this.offsetX = FIT_PAD.left + room.w / 2 - cx * this.scale;
    this.offsetY = FIT_PAD.top + room.h / 2 + cy * this.scale;
    this.hasFit = true;
    this.schedule();
  }

  zoomBy(factor, px = this.width / 2, py = this.height / 2) {
    const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, this.scale * factor));
    const real = next / this.scale;
    this.offsetX = px - (px - this.offsetX) * real;
    this.offsetY = py - (py - this.offsetY) * real;
    this.scale = next;
    this.moved = true;
    this.schedule();
  }

  zoomAt(event, factor) {
    const rect = this.canvas.getBoundingClientRect();
    this.zoomBy(factor, event.clientX - rect.left, event.clientY - rect.top);
  }

  panBy(dx, dy) {
    this.offsetX += dx;
    this.offsetY += dy;
    this.moved = true;
    this.schedule();
  }

  toWorld(px, py) {
    return { x: (px - this.offsetX) / this.scale, y: (this.offsetY - py) / this.scale };
  }

  toScreen(x, y) {
    return { x: this.offsetX + x * this.scale, y: this.offsetY - y * this.scale };
  }

  // --- input ---------------------------------------------------------------

  pointerDown(event) {
    if (event.button !== 0) return;
    this.canvas.setPointerCapture(event.pointerId);
    this.drag = { x: event.clientX, y: event.clientY };
    this.canvas.classList.add('is-dragging');
    this.onHover(null);
  }

  pointerMove(event) {
    if (this.drag) {
      this.panBy(event.clientX - this.drag.x, event.clientY - this.drag.y);
      this.drag = { x: event.clientX, y: event.clientY };
      return;
    }
    this.hover(event);
  }

  pointerUp(event) {
    if (!this.drag) return;
    this.drag = null;
    this.canvas.classList.remove('is-dragging');
    if (this.canvas.hasPointerCapture(event.pointerId)) {
      this.canvas.releasePointerCapture(event.pointerId);
    }
  }

  wheel(event) {
    event.preventDefault();
    const factor = Math.exp(-event.deltaY * (event.ctrlKey ? 0.01 : 0.0016));
    this.zoomAt(event, factor);
  }

  keyDown(event) {
    const step = 64;
    const moves = {
      ArrowLeft: [step, 0],
      ArrowRight: [-step, 0],
      ArrowUp: [0, step],
      ArrowDown: [0, -step],
    };
    if (moves[event.key]) this.panBy(...moves[event.key]);
    else if (event.key === '+' || event.key === '=') this.zoomBy(1.4);
    else if (event.key === '-' || event.key === '_') this.zoomBy(1 / 1.4);
    else if (event.key === '0') this.fit();
    else return;
    event.preventDefault();
  }

  hover(event) {
    const rect = this.canvas.getBoundingClientRect();
    const px = event.clientX - rect.left;
    const py = event.clientY - rect.top;
    let pin = null;
    if (this.layers.routers) {
      for (const item of this.scene.pins) {
        if (!this.onFloor(item)) continue;
        const at = this.toScreen(item.x, item.y);
        if (Math.hypot(at.x - px, at.y - py) <= PIN_RADIUS + 3) pin = item;
      }
    }
    const world = this.toWorld(px, py);
    const cell = pin
      ? null
      : findCell(this.scene.cells, world.x, world.y, (item) => this.cellVisible(item));
    this.onHover(pin || cell ? { pin, cell, px, py } : null);
  }

  // --- drawing -------------------------------------------------------------

  schedule() {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      this.draw();
    });
  }

  hatchPattern() {
    if (this.hatch) return this.hatch;
    const size = Math.round(8 * this.ratio);
    const tile = document.createElement('canvas');
    tile.width = size;
    tile.height = size;
    const t = tile.getContext('2d');
    t.strokeStyle = 'rgba(6, 10, 18, 0.55)';
    t.lineWidth = Math.max(1, this.ratio * 1.4);
    t.beginPath();
    t.moveTo(0, size);
    t.lineTo(size, 0);
    t.moveTo(-size / 2, size / 2);
    t.lineTo(size / 2, -size / 2);
    t.moveTo(size / 2, size * 1.5);
    t.lineTo(size * 1.5, size / 2);
    t.stroke();
    this.hatch = this.ctx.createPattern(tile, 'repeat');
    return this.hatch;
  }

  draw() {
    const ctx = this.ctx;
    const ratio = this.ratio;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    this.drawGuides(ctx);
    this.drawCells(ctx);
    this.drawLines(ctx);
    if (this.layers.routers) this.drawPins(ctx);
    this.onScale(1 / this.scale);
  }

  // Faint dots every metre (or every 5, 10, 50 as you zoom out) so there is
  // something to judge distance against between cells.
  drawGuides(ctx) {
    let spacing = 1;
    for (const step of [1, 5, 10, 50, 100, 500]) {
      spacing = step;
      if (step * this.scale >= 22) break;
    }
    const topLeft = this.toWorld(0, 0);
    const bottomRight = this.toWorld(this.width, this.height);
    const startX = Math.floor(topLeft.x / spacing) * spacing;
    const startY = Math.floor(bottomRight.y / spacing) * spacing;
    ctx.fillStyle = 'rgba(157, 176, 204, 0.18)';
    let count = 0;
    for (let x = startX; x <= bottomRight.x && count < 40000; x += spacing) {
      for (let y = startY; y <= topLeft.y && count < 40000; y += spacing) {
        const at = this.toScreen(x, y);
        ctx.fillRect(at.x - 0.75, at.y - 0.75, 1.5, 1.5);
        count += 1;
      }
    }
  }

  drawCells(ctx) {
    const side = this.scale;
    const pattern = this.hatchPattern();
    for (const cell of this.scene.cells) {
      if (!this.cellVisible(cell)) continue;
      const a = this.toScreen(cell.x0, cell.y1);
      const w = (cell.x1 - cell.x0) * side;
      const h = (cell.y1 - cell.y0) * side;
      if (a.x > this.width || a.y > this.height || a.x + w < 0 || a.y + h < 0) continue;
      ctx.globalAlpha = 0.62;
      ctx.fillStyle = LEVELS[cell.level].color;
      // A half-pixel overlap hides the seams between neighbouring cells.
      ctx.fillRect(a.x, a.y, w + 0.5, h + 0.5);
      if (cell.level === 'dead' && w >= 5) {
        ctx.globalAlpha = 1;
        ctx.save();
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.fillStyle = pattern;
        ctx.fillRect(
          a.x * this.ratio,
          a.y * this.ratio,
          (w + 0.5) * this.ratio,
          (h + 0.5) * this.ratio,
        );
        ctx.restore();
      }
    }
    ctx.globalAlpha = 1;
  }

  drawLines(ctx) {
    for (const line of this.scene.lines) {
      if (!this.onFloor(line)) continue;
      const style = LINK_STYLE[line.status] || LINK_STYLE.covered;
      const a = this.toScreen(line.ax, line.ay);
      const b = this.toScreen(line.bx, line.by);
      ctx.save();
      ctx.lineCap = 'round';
      // A dark under-stroke keeps the link readable over any cell colour.
      ctx.strokeStyle = 'rgba(6, 10, 18, 0.85)';
      ctx.lineWidth = style.width + 3;
      ctx.setLineDash(style.dash);
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.lineTo(b.x, b.y);
      ctx.stroke();
      ctx.strokeStyle = style.color;
      ctx.lineWidth = style.width;
      ctx.stroke();
      ctx.restore();
    }
  }

  drawPins(ctx) {
    for (const pin of this.scene.pins) {
      if (!this.onFloor(pin)) continue;
      const at = this.toScreen(pin.x, pin.y);
      if (at.x < -20 || at.y < -20 || at.x > this.width + 20 || at.y > this.height + 20) continue;
      const main = pin.role === 'likely_main';
      ctx.save();
      ctx.translate(at.x, at.y);
      ctx.globalAlpha = pin.low ? 0.7 : 1;
      ctx.beginPath();
      if (main) {
        // Likely main router: a rounded square, so it differs by shape and not
        // only by colour.
        const r = PIN_RADIUS + 1;
        ctx.roundRect(-r, -r, 2 * r, 2 * r, 4);
      } else {
        ctx.arc(0, 0, PIN_RADIUS, 0, 2 * Math.PI);
      }
      ctx.fillStyle = pin.low ? '#0D1524' : '#1D4ED8';
      ctx.fill();
      ctx.lineWidth = 2;
      ctx.strokeStyle = '#EAF1FB';
      ctx.setLineDash(pin.low ? [3, 2.5] : []);
      ctx.stroke();
      if (pin.number != null) {
        ctx.setLineDash([]);
        ctx.fillStyle = '#EAF1FB';
        ctx.font = '700 11px ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(String(pin.number), 0, 0.5);
      }
      ctx.restore();
    }
  }

  destroy() {
    this.resizer.disconnect();
    if (this.frame) cancelAnimationFrame(this.frame);
  }
}
