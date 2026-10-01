// The footer's dot field (markup: footer() in src/pages/layout.ts). Every footer is a halftone field that, as the
// page lifts away, assembles left to right into a giant dotted "farside". An ember dot follows the pointer (or
// wanders on its own) and the dots reach toward it; a click or tap sends a shockwave through them.
//
// Cost: nothing runs until the page end is near; then one canvas, ≤ 2× DPR (less on huge screens), drawn only
// while some of the footer is showing and the tab is visible. Reduce Motion, Save-Data or the pause button get
// one still frame of the finished wordmark.

import { motionAllowed, onMotionChange } from "./motion";

const BONE = [237, 232, 223];
const EMBER = [255, 91, 31];
const HEAT_LEVELS = 6;
const TAU = Math.PI * 2;

type Wave = { x: number; y: number; t0: number };

const clamp = (v: number, a: number, b: number) => Math.max(a, Math.min(b, v));
const smooth = (t: number) => t * t * (3 - 2 * t);
const wait = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const idle = (fn: () => void) => (typeof requestIdleCallback === "function" ? requestIdleCallback(fn, { timeout: 800 }) : setTimeout(fn, 60));

export function initFooter(fonts: Promise<void>) {
  const foot = document.querySelector<HTMLElement>(".site-footer");
  const main = document.getElementById("main");
  const cv = foot?.querySelector<HTMLCanvasElement>(".foot-cv");
  if (!foot || !main || !cv || typeof cv.getContext !== "function") return;

  let field: Field | null = null;
  let starting = false;

  /** How much of the footer is showing, 0–1 (the page sheet covers the rest). */
  const reveal = () => {
    const h = window.innerHeight;
    const fr = foot.getBoundingClientRect();
    const top = Math.max(fr.top, main.getBoundingClientRect().bottom);
    const bot = Math.min(fr.bottom, h);
    return clamp((bot - top) / Math.max(1, fr.height), 0, 1);
  };

  const check = () => {
    const r = reveal();
    if (motionAllowed()) foot.style.setProperty("--rv", r.toFixed(3));
    else foot.style.removeProperty("--rv");
    if (field) return field.setReveal(r);
    if (starting || main.getBoundingClientRect().bottom > window.innerHeight * 2.2) return;
    starting = true;
    Promise.race([fonts, wait(2500)]).then(() =>
      idle(() => {
        field = new Field(cv, foot);
        field.setReveal(reveal());
      }),
    );
  };

  window.addEventListener("scroll", check, { passive: true });
  window.addEventListener("resize", check);
  onMotionChange(check);
  check();
}

class Field {
  private ctx: CanvasRenderingContext2D;
  private W = 0;
  private H = 0;
  private dpr = 1;
  private step = 10;
  private n = 0;
  private hx = new Float32Array(0);
  private hy = new Float32Array(0);
  private x = new Float32Array(0);
  private y = new Float32Array(0);
  private vx = new Float32Array(0);
  private vy = new Float32Array(0);
  private cov = new Float32Array(0);
  private delay = new Float32Array(0);
  private drop = new Float32Array(0);
  private band = { x: 0, y: 0, w: 0, h: 0 };
  private target = 0;
  private shown = 0;
  private arrived = false;
  private ptr = { x: 0, y: 0, until: 0 };
  private ember = { x: 0, y: 0, o: 0 };
  private waves: Wave[] = [];
  private raf = 0;
  private last = 0;
  private t = 0;
  private still: boolean;
  private resizeRaf = 0;

  constructor(private cv: HTMLCanvasElement, private foot: HTMLElement) {
    this.ctx = cv.getContext("2d")!;
    this.still = !motionAllowed();
    this.layout();
    this.listen();
    new ResizeObserver(() => {
      cancelAnimationFrame(this.resizeRaf);
      this.resizeRaf = requestAnimationFrame(() => {
        this.layout();
        if (!this.raf) this.draw();
      });
    }).observe(foot);
    onMotionChange(() => {
      this.still = !motionAllowed();
      this.sync();
      if (this.still) this.draw();
    });
    document.addEventListener("visibilitychange", () => this.sync());
  }

  setReveal(r: number) {
    this.target = r;
    if (this.still) this.shown = 1;
    this.sync();
    if (!this.raf && r > 0) this.draw();
  }

  /** Run the loop only while some footer shows, the tab is visible and motion is allowed. */
  private sync() {
    const on = !this.still && this.target > 0 && !document.hidden;
    if (on && !this.raf) {
      this.last = 0;
      this.raf = requestAnimationFrame(this.frame);
    } else if (!on && this.raf) {
      cancelAnimationFrame(this.raf);
      this.raf = 0;
    }
  }

  private listen() {
    const at = (e: PointerEvent) => {
      const r = this.cv.getBoundingClientRect();
      return { x: e.clientX - r.left, y: e.clientY - r.top };
    };
    this.foot.addEventListener("pointermove", (e) => {
      const p = at(e);
      this.ptr = { ...p, until: this.t + (e.pointerType === "mouse" ? 2500 : 1500) };
    });
    this.foot.addEventListener("pointerdown", (e) => {
      if (!e.isPrimary || (e.target as Element).closest("a, button")) return;
      const p = at(e);
      this.ptr = { ...p, until: this.t + 1800 };
      if (!this.still) this.waves.push({ ...p, t0: this.t });
    });
    this.foot.addEventListener("pointerleave", () => (this.ptr.until = this.t + 300));
  }

  private layout() {
    const fr = this.foot.getBoundingClientRect();
    const W = Math.round(fr.width), H = Math.round(fr.height);
    if (!W || !H) return;
    // Keep the field honest on its own: when the links don't fit the screen, let the footer follow the page.
    const inner = this.foot.querySelector<HTMLElement>(".foot-in");
    this.foot.classList.toggle("foot-flow", !!inner && inner.scrollHeight > window.innerHeight + 1);
    let dpr = Math.min(2, window.devicePixelRatio || 1);
    if (W * H * dpr * dpr > 3.6e6) dpr = Math.max(1, Math.sqrt(3.6e6 / (W * H)));
    this.W = W;
    this.H = H;
    this.dpr = dpr;
    this.cv.width = Math.round(W * dpr);
    this.cv.height = Math.round(H * dpr);
    const mark = this.foot.querySelector<HTMLElement>(".foot-mark")!.getBoundingClientRect();
    this.band = { x: mark.left - fr.left, y: mark.top - fr.top, w: mark.width, h: mark.height };
    this.step = W < 640 ? 7 : W < 1100 ? 9 : 11;
    this.build();
  }

  /** Lay the grid and work out how much of each cell the wordmark covers (supersampled text, 4 × 4 per cell). */
  private build() {
    const { W, H, step } = this;
    const cols = Math.ceil(W / step), rows = Math.ceil(H / step);
    const n = cols * rows;
    this.n = n;
    this.hx = new Float32Array(n);
    this.hy = new Float32Array(n);
    this.cov = new Float32Array(n);
    this.delay = new Float32Array(n);
    this.drop = new Float32Array(n);
    const S = 4;
    const off = document.createElement("canvas");
    off.width = cols * S;
    off.height = rows * S;
    const o = off.getContext("2d", { willReadFrequently: true })!;
    const b = this.band;
    const k = S / step;
    const word = "farside";
    const family = '"Doto", "Doto Fallback", ui-monospace, monospace';
    o.font = `800 100px ${family}`;
    const m = o.measureText(word);
    const asc = m.actualBoundingBoxAscent || 72, desc = m.actualBoundingBoxDescent || 0;
    const size = Math.min((b.w * 0.94) / m.width, (b.h * 0.92) / ((asc + desc) / 100)) * 100;
    o.font = `800 ${size * k}px ${family}`;
    o.textAlign = "center";
    o.textBaseline = "alphabetic";
    o.fillStyle = "#fff";
    const base = (b.y + b.h / 2 + ((asc - desc) / 200) * size) * k;
    o.fillText(word, (b.x + b.w / 2) * k, base);
    const px = o.getImageData(0, 0, off.width, off.height).data;
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const i = r * cols + c;
        let a = 0;
        for (let sy = 0; sy < S; sy++) for (let sx = 0; sx < S; sx++) a += px[((r * S + sy) * off.width + c * S + sx) * 4 + 3]!;
        this.cov[i] = a / (255 * S * S);
        this.hx[i] = c * step + step / 2;
        this.hy[i] = r * step + step / 2;
        const rnd = Math.random();
        this.delay[i] = 0.08 + 0.55 * (this.hx[i]! / W) + 0.18 * rnd;
        this.drop[i] = H * (0.25 + 0.35 * rnd);
      }
    }
    // Centre the word in its band from the pixels actually drawn (font metrics don't describe Doto's dots well).
    let r0 = rows, r1 = -1;
    for (let i = 0; i < n; i++) if (this.cov[i]! > 0.04) {
      const r = Math.floor(i / cols);
      if (r < r0) r0 = r;
      if (r > r1) r1 = r;
    }
    const shift = r1 < 0 ? 0 : Math.round((b.y + b.h / 2) / step - (r0 + r1 + 1) / 2);
    if (shift) {
      const moved = new Float32Array(n);
      for (let i = 0; i < n; i++) {
        const r = Math.floor(i / cols) + shift;
        if (r >= 0 && r < rows) moved[r * cols + (i % cols)] = this.cov[i]!;
      }
      this.cov = moved;
    }
    this.x = Float32Array.from(this.hx);
    this.y = Float32Array.from(this.hy);
    this.vx = new Float32Array(n);
    this.vy = new Float32Array(n);
    if (!this.ember.o) {
      this.ember.x = b.x + b.w / 2;
      this.ember.y = b.y + b.h / 2;
    }
    this.foot.classList.add("drawn");
  }

  private frame = (now: number) => {
    this.raf = 0;
    const dt = this.last ? Math.min(33, now - this.last) : 16;
    this.last = now;
    this.t += dt;
    this.step1(dt);
    this.draw();
    this.sync();
  };

  /** Where the ember wants to be: the pointer while it's recent, otherwise a slow figure-eight over the word. */
  private emberTarget() {
    if (this.t < this.ptr.until) return { x: this.ptr.x, y: this.ptr.y };
    const b = this.band, t = this.t;
    return { x: b.x + b.w * (0.5 + 0.42 * Math.sin(t * 0.00027)), y: b.y + b.h * (0.5 + 0.32 * Math.sin(t * 0.00054)) };
  }

  private step1(dtMs: number) {
    const dt = dtMs / 1000;
    this.shown += (this.target - this.shown) * (1 - Math.exp(-dtMs / 220));
    if (!this.arrived && this.shown > 0.97) {
      this.arrived = true;
      this.waves.push({ x: this.band.x + this.band.w / 2, y: this.band.y + this.band.h / 2, t0: this.t });
    }
    if (this.shown < 0.05) this.arrived = false;
    const e = this.ember, tg = this.emberTarget(), f = 1 - Math.exp(-dtMs / 90);
    e.x += (tg.x - e.x) * f;
    e.y += (tg.y - e.y) * f;
    e.o += (this.shown - e.o) * (1 - Math.exp(-dtMs / 300));
    this.waves = this.waves.filter((w) => this.t - w.t0 < 1400);

    const R = this.W < 640 ? 120 : 190;
    const w2 = 0.42, om2 = 260, damp = 2 * 0.5 * Math.sqrt(om2);
    const { hx, hy, x, y, vx, vy, cov, delay, drop, shown, waves } = this;
    for (let i = 0; i < this.n; i++) {
      let tx = hx[i]!, ty = hy[i]!;
      // Assembly: the word's dots rise into place left to right as the footer is uncovered (the dot wipe).
      if (cov[i]! > 0.04) {
        const a = smooth(clamp((shown * 1.25 - delay[i]!) / 0.3, 0, 1));
        ty += (1 - a) * drop[i]!;
      }
      // Reach: dots near the ember lean toward it.
      const dx = e.x - tx, dy = e.y - ty, d = Math.hypot(dx, dy);
      if (d < R && e.o > 0.01) {
        const q = 1 - d / R;
        const pull = q * q * w2 * e.o;
        tx += dx * pull;
        ty += dy * pull;
      }
      let ax = om2 * (tx - x[i]!) - damp * vx[i]!;
      let ay = om2 * (ty - y[i]!) - damp * vy[i]!;
      // Shockwaves: a ring that pushes dots outward as it passes.
      for (const w of waves) {
        const age = (this.t - w.t0) / 1000, r = age * 900;
        const wx = x[i]! - w.x, wy = y[i]! - w.y, wd = Math.hypot(wx, wy) || 1;
        const q = 1 - Math.abs(wd - r) / 70;
        if (q > 0) {
          const s = q * 5200 * (1 - age / 1.4);
          ax += (wx / wd) * s;
          ay += (wy / wd) * s;
        }
      }
      vx[i] = vx[i]! + ax * dt;
      vy[i] = vy[i]! + ay * dt;
      x[i] = x[i]! + vx[i]! * dt;
      y[i] = y[i]! + vy[i]! * dt;
    }
  }

  draw() {
    const { ctx, W, H, dpr, n, x, y, hx, hy, cov, step } = this;
    if (!n) return;
    const still = this.still;
    const shown = still ? 1 : this.shown;
    const e = this.ember;
    const eo = still ? 0 : e.o;
    const R = W < 640 ? 120 : 190;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);

    // Background grain: tiny squares, one path.
    ctx.fillStyle = "rgba(237,232,223,0.14)";
    ctx.beginPath();
    for (let i = 0; i < n; i++) {
      if (cov[i]! > 0.04) continue;
      ctx.rect(x[i]! - 0.6, y[i]! - 0.6, 1.2, 1.2);
    }
    ctx.fill();

    // The word and anything heated by the ember, bucketed by heat so each bucket is one path.
    const paths: Path2D[] = Array.from({ length: HEAT_LEVELS }, () => new Path2D());
    const used = new Array<boolean>(HEAT_LEVELS).fill(false);
    for (let i = 0; i < n; i++) {
      const c = cov[i]!;
      const d = eo > 0.01 ? Math.hypot(e.x - hx[i]!, e.y - hy[i]!) : 1e9;
      const heat = d < R ? (1 - d / R) * eo : 0;
      if (c <= 0.04 && heat < 0.08) continue;
      let r: number;
      if (c > 0.04) {
        const a = still ? 1 : smooth(clamp((shown * 1.25 - this.delay[i]!) / 0.3, 0, 1));
        r = step * 0.47 * (0.3 + 0.7 * c) * (0.25 + 0.75 * a) * (1 + 0.35 * heat);
      } else r = 0.7 + 1.6 * heat;
      const lvl = Math.min(HEAT_LEVELS - 1, Math.floor(heat * HEAT_LEVELS));
      paths[lvl]!.moveTo(x[i]! + r, y[i]!);
      paths[lvl]!.arc(x[i]!, y[i]!, r, 0, TAU);
      used[lvl] = true;
    }
    for (let l = 0; l < HEAT_LEVELS; l++) {
      if (!used[l]) continue;
      const t = l / (HEAT_LEVELS - 1);
      const col = BONE.map((b, j) => Math.round(b + (EMBER[j]! - b) * t));
      ctx.fillStyle = `rgb(${col[0]},${col[1]},${col[2]})`;
      ctx.fill(paths[l]!);
    }

    // The ember itself: the one contact dot, with a soft glow.
    if (eo > 0.02) {
      const g = ctx.createRadialGradient(e.x, e.y, 0, e.x, e.y, 34);
      g.addColorStop(0, `rgba(255,91,31,${(0.55 * eo).toFixed(3)})`);
      g.addColorStop(1, "rgba(255,91,31,0)");
      ctx.fillStyle = g;
      ctx.fillRect(e.x - 34, e.y - 34, 68, 68);
      ctx.fillStyle = `rgba(255,91,31,${eo.toFixed(3)})`;
      ctx.beginPath();
      ctx.arc(e.x, e.y, 5.5, 0, TAU);
      ctx.fill();
    }

    // Shockwave rings, faint.
    for (const w of this.waves) {
      const age = (this.t - w.t0) / 1000;
      ctx.strokeStyle = `rgba(255,91,31,${(0.35 * (1 - age / 1.4)).toFixed(3)})`;
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.arc(w.x, w.y, age * 900, 0, TAU);
      ctx.stroke();
    }
  }
}
