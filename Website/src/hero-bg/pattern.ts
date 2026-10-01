// The curtain pattern's shape, shared by the shader (bg.ts, as GLSL) and the build-time CSS poster
// (scripts/build.ts → src/hero-bg/poster.css), so the poster is the first frame the shader draws. The hashes use
// only multiply/add/fract (no sin), which GPUs compute alike; here every step is rounded to float32 to match.

const f = Math.fround;
const fract = (x: number) => f(x - Math.floor(x));

export function h1(p: number): number {
  p = fract(f(p * 0.1031));
  p = f(p * f(p + 33.33));
  p = f(p * f(p + p));
  return fract(p);
}

export function n1(x: number): number {
  const i = Math.floor(x), t = fract(x);
  const u = f(t * t * f(3 - 2 * t));
  return f(h1(i) + (h1(i + 1) - h1(i)) * u);
}

const smoothstep = (a: number, b: number, x: number) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};

/** Start time of the loop: the shader's first frame and the poster both use it. */
export const T0 = 37;
/** Columns per hero width that may be LED dots, and the threshold that makes one. */
export const DOT_COLS = { wide: 12, narrow: 7 };
export const isDotColumn = (g: number) => h1(g * 7.31 + 2) > 0.58;
export const DOT_CELL = { wide: 10, narrow: 8 };
/** Where the bloom sits and how big it is, as fractions of the hero (shader and poster). */
export const BLOOM = { x: 0.5, y: 0.34, r: 0.46 };

/** Horizontal sway at height y (0 top, 1 bottom) and time t. */
export const sway = (y: number, t: number) => (n1(y * 2.6 + t * 0.13) - 0.5) * 0.05 * (0.25 + y) + Math.sin(t * 0.19 + y * 2.1) * 0.014 * y;

/** Band brightness (0–1) and the noise used for the ember hue, at swayed x. */
export function band(xs: number, t: number) {
  const n = n1(xs * 6 + t * 0.025);
  const b = smoothstep(0.22, 0.92, 0.5 + 0.5 * Math.sin(xs * 34 + n * 5.5 + t * 0.11));
  const len = 0.5 + 0.45 * n1(xs * 4.3 + 13.7 + t * 0.018);
  return { b, n, len };
}

export function hsv(h: number, s: number, v: number): [number, number, number] {
  const k = [0, 4, 2].map((o) => Math.min(1, Math.max(0, Math.abs(((h * 6 + o) % 6) - 3) - 1)));
  return k.map((c) => v * (1 + (c - 1) * s)) as [number, number, number];
}

const EMBER: [number, number, number][] = [
  [0.42, 0.04, 0.03],
  [1, 0.357, 0.122],
  [1, 0.58, 0.16],
  [1, 0.78, 0.3],
  [0.95, 0.36, 0.42],
];
export function ember(t: number): [number, number, number] {
  t = (t - Math.floor(t)) * 5;
  const i = Math.min(4, Math.floor(t)), a = EMBER[i]!, b = EMBER[(i + 1) % 5]!, u = t - i;
  return [0, 1, 2].map((j) => a[j]! + (b[j]! - a[j]!) * u) as [number, number, number];
}

export function curtainColor(xs: number, n: number, t: number, spectrum: boolean) {
  return spectrum ? hsv(fract(-xs * 0.92 + 0.03 * Math.sin(t * 0.09)), 0.82, 1) : ember(xs * 1.25 + n * 0.35 + t * 0.012);
}
