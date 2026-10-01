// Scene shapes from concept 21 · Reach. Drawn in "luminance" colours: bone intensity in R/G, ember in B.
// The halftone renderers read those channels back and turn them into dots.

export type Ctx = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;
type Pt = readonly [number, number];

export const Lc = (v: number) => {
  const c = Math.round(v * 255);
  return `rgb(${c},${c},0)`;
};

export function vgrad(c: Ctx, x: number, y: number, r: number, a: string, b: string) {
  const g = c.createRadialGradient(x, y, 0, x, y, r);
  g.addColorStop(0, a);
  g.addColorStop(1, b);
  return g;
}

/** A reaching hand; the index fingertip sits at the local origin and the arm runs off to −x. */
export function drawHand(c: Ctx, tx: number, ty: number, s: number, a: number) {
  c.save();
  c.translate(tx, ty);
  c.rotate(a);
  c.scale(s, s);
  const g = c.createLinearGradient(0, 0, -640, 230);
  g.addColorStop(0, Lc(1));
  g.addColorStop(0.28, Lc(0.82));
  g.addColorStop(0.6, Lc(0.46));
  g.addColorStop(1, Lc(0.18));
  const g2 = c.createLinearGradient(0, 0, -560, 200);
  g2.addColorStop(0, Lc(0.78));
  g2.addColorStop(0.35, Lc(0.6));
  g2.addColorStop(1, Lc(0.16));
  c.lineCap = "round";
  c.lineJoin = "round";
  const seg = (p: Pt[], lw: number, st: string | CanvasGradient, out = false) => {
    c.beginPath();
    c.moveTo(p[0]![0], p[0]![1]);
    for (let i = 1; i < p.length; i++) c.lineTo(p[i]![0], p[i]![1]);
    if (out) {
      c.strokeStyle = "rgb(10,10,0)";
      c.lineWidth = lw + 8;
      c.stroke();
    }
    c.strokeStyle = st;
    c.lineWidth = lw;
    c.stroke();
  };
  seg([[-440, 142], [-1000, 360]], 150, Lc(0.2));
  seg([[-240, 66], [-470, 150]], 106, g);
  c.strokeStyle = Lc(0.62);
  c.lineWidth = 5;
  c.beginPath();
  c.moveTo(-440 + 26, 142 + 68);
  c.lineTo(-440 - 26, 142 - 68);
  c.stroke();
  c.fillStyle = g;
  c.beginPath();
  c.ellipse(-206, 64, 66, 55, -0.14, 0, Math.PI * 2);
  c.fill();
  seg([[-188, 86], [-150, 98], [-136, 113], [-150, 125]], 28, g2, true);
  seg([[-182, 60], [-134, 70], [-116, 90], [-132, 106]], 33, g2, true);
  seg([[-176, 34], [-120, 42], [-98, 64], [-114, 82]], 36, g2, true);
  seg([[-176, 8], [-94, 4], [-17, 0]], 34, g, true);
  c.strokeStyle = "rgb(40,40,0)";
  c.lineWidth = 2.4;
  c.beginPath();
  c.arc(-94, 4, 10, -1.2, 1.2);
  c.stroke();
  c.beginPath();
  c.arc(-46, 2, 8, -1.1, 1.1);
  c.stroke();
  seg([[-250, 74], [-202, 66], [-156, 54], [-128, 52]], 30, g, true);
  c.restore();
}

const CUR: Pt[] = [[0, 0], [0, 250], [60, 196], [98, 284], [134, 268], [96, 180], [176, 180]];

/** The Mac pointer; its tip is the local origin. `frame` adds a faint window behind it. */
export function drawCursor(c: Ctx, tx: number, ty: number, s: number, a: number, frame: boolean) {
  c.save();
  c.translate(tx, ty);
  c.rotate(a);
  c.scale(s, s);
  if (frame) {
    c.strokeStyle = Lc(0.13);
    c.lineWidth = 3;
    c.strokeRect(80, -40, 1000, 560);
    c.beginPath();
    c.moveTo(80, -6);
    c.lineTo(1080, -6);
    c.stroke();
    c.fillStyle = Lc(0.26);
    for (const x of [102, 124, 146]) {
      c.beginPath();
      c.arc(x, -23, 6, 0, Math.PI * 2);
      c.fill();
    }
    c.fillStyle = Lc(0.07);
    for (let i = 0; i < 8; i++) c.fillRect(250, 40 + i * 34, 120 + ((i * 97) % 260), 10);
  }
  c.beginPath();
  c.moveTo(CUR[0]![0], CUR[0]![1]);
  for (let i = 1; i < CUR.length; i++) c.lineTo(CUR[i]![0], CUR[i]![1]);
  c.closePath();
  c.fillStyle = Lc(0.13);
  c.fill();
  c.lineJoin = "round";
  c.lineWidth = 13;
  c.strokeStyle = Lc(1);
  c.stroke();
  c.restore();
}

/** Ember light (blue channel) added on top of the scene: the contact beat. */
export function glow(c: Ctx, x: number, y: number, r: number, a: number) {
  c.save();
  c.globalCompositeOperation = "lighter";
  const gr = c.createRadialGradient(x, y, 0, x, y, r);
  gr.addColorStop(0, `rgba(0,0,255,${a})`);
  gr.addColorStop(1, "rgba(0,0,255,0)");
  c.fillStyle = gr;
  c.fillRect(x - r, y - r, r * 2, r * 2);
  c.restore();
}

/** Small deterministic PRNG so still frames (OG image, Reduce Motion) are identical every time. */
export function rng(seed: number) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export const easeOutExpo = (t: number) => (t >= 1 ? 1 : 1 - Math.pow(2, -10 * t));
