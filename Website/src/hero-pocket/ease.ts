export type Ease = (t: number) => number;

export const clamp = (v: number, a: number, b: number) => Math.max(a, Math.min(b, v));
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

export function bezier(x1: number, y1: number, x2: number, y2: number): Ease {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const X = (t: number) => ((ax * t + bx) * t + cx) * t;
  const Y = (t: number) => ((ay * t + by) * t + cy) * t;
  const D = (t: number) => (3 * ax * t + 2 * bx) * t + cx;
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const e = X(t) - x;
      if (Math.abs(e) < 1e-5) return Y(t);
      const d = D(t);
      if (Math.abs(d) < 1e-6) break;
      t = clamp(t - e / d, 0, 1);
    }
    let lo = 0, hi = 1;
    t = x;
    for (let i = 0; i < 32; i++) {
      const v = X(t);
      if (Math.abs(v - x) < 1e-5) break;
      if (v < x) lo = t;
      else hi = t;
      t = (lo + hi) / 2;
    }
    return Y(t);
  };
}

/** Farside motion: primary ease and reveal ease (design/FARSIDE-DESIGN-SYSTEM.md). */
export const EASE = bezier(0.16, 1, 0.3, 1);
export const REVEAL = bezier(0.22, 1, 0.36, 1);
export const IO: Ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
export const LIN: Ease = (t) => t;
