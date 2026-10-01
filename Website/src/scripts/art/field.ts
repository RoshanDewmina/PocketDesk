// Halftone field from concept 21: a scene is drawn small (one pixel per cell), read back, and every
// cell becomes a dot whose radius follows the luminance. Ember (blue channel) picks the dot colour.
// DOM-free: it draws on any 2D canvas context (the gap demo, and the build-time art in render.ts).

import { rng, type Ctx } from "./shapes";

export type Scene = (c: Ctx, W: number, H: number, t: number) => void;
export type Rect = { x: number; y: number; w: number; h: number };
export type AnyCanvas = HTMLCanvasElement | OffscreenCanvas;
type Ctx2D = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;

type Ripple = { x: number; y: number; s: number; t: number; v: number; w: number; life: number };

export type FieldOptions = {
  scene: Scene;
  /** Cell size in CSS px on wide screens and on narrow (< 640 px) screens. */
  cell?: number;
  cellSmall?: number;
  /** Share of empty cells that carry a faint flickering "dust" dot. */
  dust?: number;
  rippleWidth?: number;
  rippleLife?: number;
  seed?: number;
  /** Free-floating stars per 10,000 px² that drift slowly left and shift with `parallax` (hero starfield). */
  stars?: number;
};

type Star = { x: number; y: number; z: number; ph: number };

const BONE = "rgb(237,232,223)";
const MID = "#F7A57F";
const EMBER = "rgb(255,91,31)";
const FEATHER = 28;

export const makeCanvas = (w: number, h: number): AnyCanvas => {
  if (typeof OffscreenCanvas === "function") return new OffscreenCanvas(w, h);
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  return c;
};

export class Field {
  W = 1;
  H = 1;
  cell = 7;
  cols = 1;
  rows = 1;
  dpr = 1;
  mouse = { x: -999, y: -999, a: 0 };
  /** -1…1 on each axis; near stars move up to ~16 px with it. */
  parallax = { x: 0, y: 0 };
  private stars: Star[] = [];
  private dust = new Float32Array(0);
  private damp: Float32Array | null = null;
  private quietRects: Rect[] = [];
  private rip: Ripple[] = [];
  private ctx: Ctx2D;
  private off: AnyCanvas;
  private oc: Ctx2D;

  constructor(
    private cv: AnyCanvas,
    private o: FieldOptions,
  ) {
    this.ctx = cv.getContext("2d") as Ctx2D;
    this.off = makeCanvas(1, 1);
    this.oc = this.off.getContext("2d", { willReadFrequently: true }) as Ctx2D;
  }

  /** Size in CSS px and the backing-store scale. */
  resize(W: number, H: number, dpr: number) {
    this.W = Math.max(1, W);
    this.H = Math.max(1, H);
    this.dpr = dpr;
    this.cv.width = Math.round(this.W * dpr);
    this.cv.height = Math.round(this.H * dpr);
    this.cell = this.W < 640 ? (this.o.cellSmall ?? 5.5) : (this.o.cell ?? 7);
    this.cols = Math.ceil(this.W / this.cell);
    this.rows = Math.ceil(this.H / this.cell);
    this.off.width = this.cols;
    this.off.height = this.rows;
    const rand = rng(this.o.seed ?? 21);
    const share = this.o.dust ?? 0.06;
    this.dust = new Float32Array(this.cols * this.rows);
    for (let i = 0; i < this.dust.length; i++) this.dust[i] = rand() < share ? 0.4 + rand() * 0.6 : 0;
    const count = Math.round(((this.W * this.H) / 10000) * (this.o.stars ?? 0));
    this.stars = Array.from({ length: count }, () => ({ x: rand() * this.W, y: rand() * this.H, z: 0.25 + rand() * 0.75, ph: rand() * 6.28 }));
    this.buildDamp();
  }

  /** Keep dots out from behind text: cells inside these rects (CSS px) fade to empty void. */
  setQuiet(rects: Rect[]) {
    this.quietRects = rects;
    this.buildDamp();
  }

  private buildDamp() {
    if (!this.quietRects.length) {
      this.damp = null;
      return;
    }
    const { cols, rows, cell } = this;
    const d = new Float32Array(cols * rows).fill(1);
    // Only the cells within FEATHER of a rect can change, so visit just that window per rect.
    for (const r of this.quietRects) {
      const x0 = Math.max(0, Math.floor((r.x - FEATHER) / cell));
      const x1 = Math.min(cols - 1, Math.ceil((r.x + r.w + FEATHER) / cell));
      const y0 = Math.max(0, Math.floor((r.y - FEATHER) / cell));
      const y1 = Math.min(rows - 1, Math.ceil((r.y + r.h + FEATHER) / cell));
      for (let y = y0; y <= y1; y++) {
        const cy = (y + 0.5) * cell;
        const dy = Math.max(r.y - cy, 0, cy - (r.y + r.h));
        for (let x = x0; x <= x1; x++) {
          const cx = (x + 0.5) * cell;
          const dx = Math.max(r.x - cx, 0, cx - (r.x + r.w));
          const dist = Math.sqrt(dx * dx + dy * dy);
          if (dist < FEATHER) {
            const i = y * cols + x;
            const k = dist / FEATHER;
            if (k < d[i]!) d[i] = k;
          }
        }
      }
    }
    this.damp = d;
  }

  ripple(x: number, y: number, s: number, t: number, v = 780) {
    this.rip.push({ x, y, s, t, v, w: this.o.rippleWidth ?? 56, life: this.o.rippleLife ?? 1.9 });
  }

  clearRipples() {
    this.rip = [];
  }

  draw(t: number) {
    const { cols, rows, cell, oc, ctx, dust, damp } = this;
    oc.setTransform(1, 0, 0, 1, 0, 0);
    oc.globalCompositeOperation = "source-over";
    oc.fillStyle = "#000";
    oc.fillRect(0, 0, cols, rows);
    oc.setTransform(cols / this.W, 0, 0, rows / this.H, 0, 0);
    this.o.scene(oc, this.W, this.H, t);
    const d = oc.getImageData(0, 0, cols, rows).data;

    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    ctx.clearRect(0, 0, this.W, this.H);
    const pB = new Path2D();
    const pM = new Path2D();
    const pE = new Path2D();
    const R = (this.rip = this.rip.filter((k) => t - k.t < k.life));
    const m = this.mouse;
    const rr = cell * 0.5 * 1.12;
    const TAU = Math.PI * 2;

    for (let y = 0; y < rows; y++) {
      for (let x = 0; x < cols; x++) {
        const i = y * cols + x;
        const q = damp ? damp[i]! : 1;
        if (q <= 0) continue;
        let L = d[i * 4]! / 255;
        const E = d[i * 4 + 2]! / 255;
        const cx = (x + 0.5) * cell;
        const cy = (y + 0.5) * cell;
        if (L < 0.03) {
          const du = dust[i]!;
          L = du > 0 ? du * 0.09 * (0.55 + 0.45 * Math.sin(t * 1.7 + i * 0.7)) : 0;
        }
        let rp = 0;
        let ox = 0;
        let oy = 0;
        for (let k = 0; k < R.length; k++) {
          const r = R[k]!;
          const dx = cx - r.x;
          const dy = cy - r.y;
          const dd = Math.sqrt(dx * dx + dy * dy);
          const age = t - r.t;
          const b0 = (dd - age * r.v) / r.w;
          const b = Math.exp(-b0 * b0) * r.s * (1 - age / r.life);
          if (b > 0.02) {
            rp += b;
            const inv = 1 / (dd || 1);
            ox += dx * inv * b * 4;
            oy += dy * inv * b * 4;
          }
        }
        if (m.a > 0) {
          const mx = cx - m.x;
          const my = cy - m.y;
          const md = mx * mx + my * my;
          if (md < 22500) L += (1 - Math.sqrt(md) / 150) * m.a * (L > 0.03 ? 0.18 : 0.12);
        }
        let lum = L + rp * (L > 0.05 ? 0.4 : 0.26);
        if (E > 0.05) lum = Math.max(lum, E * 0.62);
        lum *= q;
        if (lum > 1) lum = 1;
        const r = rr * Math.sqrt(lum);
        if (r < 0.38) continue;
        const e = E + rp * 0.9;
        const P = e > 0.5 ? pE : e > 0.18 ? pM : pB;
        const px = cx + ox;
        const py = cy + oy;
        P.moveTo(px + r, py);
        P.arc(px, py, r, 0, TAU);
      }
    }
    ctx.fillStyle = BONE;
    ctx.fill(pB);
    ctx.fillStyle = MID;
    ctx.fill(pM);
    ctx.fillStyle = EMBER;
    ctx.fill(pE);
    if (this.stars.length) this.drawStars(t, d);
  }

  /** The starfield: small bone dots between the grid, kept out of the art and out from behind text. */
  private drawStars(t: number, d: Uint8ClampedArray) {
    const { ctx, cols, rows, cell, damp, W, H } = this;
    const near = new Path2D();
    const far = new Path2D();
    const TAU = Math.PI * 2;
    for (const s of this.stars) {
      let x = (s.x - t * (3 + 9 * s.z) + this.parallax.x * 16 * s.z) % W;
      if (x < 0) x += W;
      const y = s.y + this.parallax.y * 10 * s.z;
      const gx = Math.floor(x / cell);
      const gy = Math.floor(y / cell);
      if (gx < 0 || gy < 0 || gx >= cols || gy >= rows) continue;
      const i = gy * cols + gx;
      if (damp && damp[i]! < 0.9) continue;
      if (d[i * 4]! > 12 || d[i * 4 + 2]! > 12) continue;
      const tw = 0.6 + 0.4 * Math.sin(t * (0.8 + s.z) + s.ph);
      const r = (0.45 + 0.75 * s.z) * tw;
      const P = s.z > 0.65 ? near : far;
      P.moveTo(x + r, y);
      P.arc(x, y, r, 0, TAU);
    }
    ctx.fillStyle = BONE;
    ctx.globalAlpha = 0.85;
    ctx.fill(near);
    ctx.globalAlpha = 0.45;
    ctx.fill(far);
    ctx.globalAlpha = 1;
  }
}
