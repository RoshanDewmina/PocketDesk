// The halftone dot field behind the devices (as in A2) that lights ember from each tap, plus the ember pulse
// that crosses the gap on Connect, drawn on a canvas above the devices.

import type { Clock } from "./clock";
import { IO } from "./ease";

type Pt = { x: number; y: number };
type Ripple = { x: number; y: number; t0: number; max: number };
type Pulse = { a: Pt; b: Pt; c: Pt; t0: number; ms: number };

const RIPPLE_MS = 1150;
const TAU = Math.PI * 2;

export class Field {
  private bg: CanvasRenderingContext2D;
  private fg: CanvasRenderingContext2D;
  private w = 0;
  private h = 0;
  private d = 1;
  private dots: number[] = [];
  private ripples: Ripple[] = [];
  private pulses: Pulse[] = [];
  private now = 0;
  private live = false;

  constructor(private bgCv: HTMLCanvasElement, private fgCv: HTMLCanvasElement, clock: Clock | null, private step = 13) {
    this.bg = bgCv.getContext("2d")!;
    this.fg = fgCv.getContext("2d")!;
    clock?.add((dt) => {
      this.now += dt;
      if (this.ripples.length || this.pulses.length || this.live) this.draw();
    });
  }

  resize(W: number, H: number, k: number) {
    this.d = Math.min(2, devicePixelRatio || 1) * k;
    this.w = W;
    this.h = H;
    for (const cv of [this.bgCv, this.fgCv]) {
      cv.width = Math.max(1, Math.round(W * this.d));
      cv.height = Math.max(1, Math.round(H * this.d));
      cv.style.width = `${W}px`;
      cv.style.height = `${H}px`;
    }
    this.dots = [];
    const s = this.step;
    for (let y = s / 2; y < H; y += s) for (let x = s / 2; x < W; x += s) this.dots.push(x, y);
    this.draw();
  }

  clear() {
    this.ripples = [];
    this.pulses = [];
    this.live = true;
  }

  ripple(x: number, y: number) {
    this.ripples.push({ x, y, t0: this.now, max: Math.hypot(this.w, this.h) * 0.8 });
  }

  pulse(a: Pt, b: Pt, ms: number) {
    const c = { x: (a.x + b.x) / 2, y: Math.min(a.y, b.y) - Math.abs(a.x - b.x) * 0.3 - 50 };
    this.pulses.push({ a, b, c, t0: this.now, ms });
  }

  private at(p: Pulse, t: number): Pt {
    const u = 1 - t;
    return { x: u * u * p.a.x + 2 * u * t * p.c.x + t * t * p.b.x, y: u * u * p.a.y + 2 * u * t * p.c.y + t * t * p.b.y };
  }

  draw() {
    const { bg, fg, d, now } = this;
    this.live = false;
    this.ripples = this.ripples.filter((r) => now - r.t0 < RIPPLE_MS);
    this.pulses = this.pulses.filter((p) => now - p.t0 < p.ms + 300);
    bg.setTransform(d, 0, 0, d, 0, 0);
    bg.clearRect(0, 0, this.w, this.h);
    fg.setTransform(d, 0, 0, d, 0, 0);
    fg.clearRect(0, 0, this.w, this.h);

    const heads: [number, number, number][] = [];
    for (const p of this.pulses) {
      const raw = (now - p.t0) / p.ms;
      const fade = raw > 1 ? Math.max(0, 1 - ((raw - 1) * p.ms) / 300) : 1;
      for (let i = 0; i < 12; i++) {
        const t = raw - i * 0.035;
        if (t < 0 || t > 1) continue;
        const q = this.at(p, IO(t));
        heads.push([q.x, q.y, (1 - i / 12) * fade]);
      }
    }

    const hot: number[] = [];
    bg.fillStyle = "rgba(237,232,223,.085)";
    bg.beginPath();
    const dots = this.dots;
    for (let i = 0; i < dots.length; i += 2) {
      const x = dots[i]!, y = dots[i + 1]!;
      let e = 0;
      for (const r of this.ripples) {
        const a = (now - r.t0) / RIPPLE_MS, R = a * r.max, q = 1 - Math.abs(Math.hypot(x - r.x, y - r.y) - R) / 44;
        if (q > 0) e = Math.max(e, q * q * (1 - a));
      }
      for (const [hx, hy, s] of heads) {
        const q = 1 - Math.hypot(x - hx, y - hy) / 30;
        if (q > 0) e = Math.max(e, q * s * 0.8);
      }
      if (e > 0.03) hot.push(x, y, e);
      else {
        bg.moveTo(x + 1, y);
        bg.arc(x, y, 1, 0, TAU);
      }
    }
    bg.fill();
    for (let i = 0; i < hot.length; i += 3) {
      const e = hot[i + 2]!;
      bg.fillStyle = `rgba(255,91,31,${(0.15 + 0.75 * e).toFixed(3)})`;
      bg.beginPath();
      bg.arc(hot[i]!, hot[i + 1]!, 1 + 2 * e, 0, TAU);
      bg.fill();
    }

    // The pulse itself rides above the devices: a trail of ember halftone dots and a glowing head.
    for (const [x, y, s] of heads) {
      fg.fillStyle = `rgba(255,91,31,${(0.25 + 0.7 * s).toFixed(3)})`;
      fg.beginPath();
      fg.arc(x, y, 1.2 + 3.2 * s, 0, TAU);
      fg.fill();
    }
    for (const p of this.pulses) {
      const t = (now - p.t0) / p.ms;
      if (t > 1) continue;
      const q = this.at(p, IO(t));
      const g = fg.createRadialGradient(q.x, q.y, 0, q.x, q.y, 22);
      g.addColorStop(0, "rgba(255,91,31,.95)");
      g.addColorStop(0.3, "rgba(255,91,31,.45)");
      g.addColorStop(1, "rgba(255,91,31,0)");
      fg.fillStyle = g;
      fg.fillRect(q.x - 22, q.y - 22, 44, 44);
    }
  }
}
