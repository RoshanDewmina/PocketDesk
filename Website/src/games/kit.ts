// Small shared pieces for the footer games: batched dot drawing, spark bursts, the dotted wordmark as cells,
// and best scores in localStorage.

export const BONE = "#ede8df";
export const EMBER = "#ff5b1f";
export const TAU = Math.PI * 2;

export const clamp = (v: number, a: number, b: number) => Math.max(a, Math.min(b, v));
export const rand = (a: number, b: number) => a + Math.random() * (b - a);

/** Bone (0) to ember (1) in six steps. */
const HEAT = Array.from({ length: 6 }, (_, l) => {
  const t = l / 5;
  const c = [[237, 232, 223], [255, 91, 31]];
  return `rgb(${[0, 1, 2].map((j) => Math.round(c[0]![j]! + (c[1]![j]! - c[0]![j]!) * t)).join(",")})`;
});
export const heatColor = (h: number) => HEAT[Math.round(clamp(h, 0, 1) * 5)]!;

export const coarse = () => window.matchMedia("(pointer: coarse)").matches;

/** Dots batched by colour: one path and one fill per colour per frame. */
export class Ink {
  private paths = new Map<string, Path2D>();
  dot(color: string, x: number, y: number, r: number) {
    let p = this.paths.get(color);
    if (!p) this.paths.set(color, (p = new Path2D()));
    p.moveTo(x + r, y);
    p.arc(x, y, r, 0, TAU);
  }
  flush(ctx: CanvasRenderingContext2D) {
    for (const [c, p] of this.paths) {
      ctx.fillStyle = c;
      ctx.fill(p);
    }
    this.paths.clear();
  }
}

/** Short-lived dots thrown out by a burst. */
export class Sparks {
  private x: number[] = [];
  private y: number[] = [];
  private vx: number[] = [];
  private vy: number[] = [];
  private life: number[] = [];
  private col: string[] = [];
  constructor(private max = 360, private gravity = 520) {}
  burst(x: number, y: number, n: number, speed: number, color: string, life = 0.7) {
    for (let i = 0; i < n; i++) {
      if (this.x.length >= this.max) this.kill(0);
      const a = Math.random() * TAU, s = speed * (0.35 + Math.random() * 0.65);
      this.x.push(x);
      this.y.push(y);
      this.vx.push(Math.cos(a) * s);
      this.vy.push(Math.sin(a) * s - speed * 0.3);
      this.life.push(life * (0.6 + Math.random() * 0.4));
      this.col.push(color);
    }
  }
  /** A directed puff (exhaust): `dir` in radians, a little spread. */
  puff(x: number, y: number, dir: number, speed: number, color: string, life = 0.35) {
    if (this.x.length >= this.max) this.kill(0);
    const a = dir + rand(-0.35, 0.35), s = speed * rand(0.6, 1);
    this.x.push(x);
    this.y.push(y);
    this.vx.push(Math.cos(a) * s);
    this.vy.push(Math.sin(a) * s);
    this.life.push(life * rand(0.6, 1));
    this.col.push(color);
  }
  private kill(i: number) {
    for (const a of [this.x, this.y, this.vx, this.vy, this.life]) a.splice(i, 1);
    this.col.splice(i, 1);
  }
  step(dt: number) {
    for (let i = this.x.length - 1; i >= 0; i--) {
      this.life[i]! -= dt;
      if (this.life[i]! <= 0) {
        this.kill(i);
        continue;
      }
      this.vy[i]! += this.gravity * dt;
      this.x[i]! += this.vx[i]! * dt;
      this.y[i]! += this.vy[i]! * dt;
    }
  }
  draw(ink: Ink, r: number) {
    for (let i = 0; i < this.x.length; i++) ink.dot(this.col[i]!, this.x[i]!, this.y[i]!, r * clamp(this.life[i]! * 2.2, 0.25, 1));
  }
  clear() {
    for (const a of [this.x, this.y, this.vx, this.vy, this.life]) a.length = 0;
    this.col.length = 0;
  }
}

/**
 * The wordmark "farside" in Doto, fitted into `rect` (0.94 of its width at most), sampled on a `pitch` grid
 * covering w × h. Returns the coverage (0–1) of each cell, row by row, plus the grid size.
 */
export function wordCells(w: number, h: number, pitch: number, rect: { x: number; y: number; w: number; h: number }) {
  const cols = Math.max(1, Math.floor(w / pitch)), rows = Math.max(1, Math.floor(h / pitch));
  const S = 4;
  const off = document.createElement("canvas");
  off.width = cols * S;
  off.height = rows * S;
  const o = off.getContext("2d", { willReadFrequently: true })!;
  const k = S / pitch;
  const family = '"Doto", "Doto Fallback", ui-monospace, monospace';
  o.font = `800 100px ${family}`;
  const m = o.measureText("farside");
  const asc = m.actualBoundingBoxAscent || 72, desc = m.actualBoundingBoxDescent || 0;
  const size = Math.min((rect.w * 0.94) / m.width, (rect.h * 0.92) / ((asc + desc) / 100)) * 100;
  o.font = `800 ${size * k}px ${family}`;
  o.textAlign = "center";
  o.textBaseline = "alphabetic";
  o.fillStyle = "#fff";
  o.fillText("farside", (rect.x + rect.w / 2) * k, (rect.y + rect.h / 2 + ((asc - desc) / 200) * size) * k);
  const px = o.getImageData(0, 0, off.width, off.height).data;
  const cov = new Float32Array(cols * rows);
  for (let r = 0; r < rows; r++)
    for (let c = 0; c < cols; c++) {
      let a = 0;
      for (let sy = 0; sy < S; sy++) for (let sx = 0; sx < S; sx++) a += px[((r * S + sy) * off.width + c * S + sx) * 4 + 3]!;
      cov[r * cols + c] = a / (255 * S * S);
    }
  return { cols, rows, cov };
}

const KEY = (id: string) => `farside:arcade:${id}`;
export function loadBest(id: string): number | null {
  try {
    const v = window.localStorage.getItem(KEY(id));
    return v === null ? null : Number(v) || null;
  } catch {
    return null;
  }
}
export function saveBest(id: string, v: number) {
  try {
    window.localStorage.setItem(KEY(id), String(Math.round(v)));
  } catch {
    /* storage blocked: the best score lasts for this page only */
  }
}
