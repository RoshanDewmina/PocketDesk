// Static 1-bit art from concept 21 (Bayer 8×8 or Atkinson), used for the "How it works" cards.

import { drawCursor, drawHand, glow, Lc, vgrad, type Ctx } from "./shapes";

const B8 = [
  0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22, 3,
  35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25, 15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
];
const BONE = [237, 232, 223] as const;
const EMBER = [255, 91, 31] as const;

export type Art = { px?: number; mode?: "bayer" | "atkinson"; draw: (c: Ctx, W: number, H: number) => void };

export function dither(cv: HTMLCanvasElement, art: Art, W: number, H: number) {
  const px = art.px ?? 2;
  const w = Math.ceil(W / px);
  const h = Math.ceil(H / px);
  const off = document.createElement("canvas");
  off.width = w;
  off.height = h;
  const c = off.getContext("2d", { willReadFrequently: true })!;
  c.fillStyle = "#000";
  c.fillRect(0, 0, w, h);
  c.save();
  c.scale(w / W, h / H);
  art.draw(c, W, H);
  c.restore();
  const src = c.getImageData(0, 0, w, h).data;
  const out = c.createImageData(w, h);
  const od = out.data;
  const n = w * h;
  const L = new Float32Array(n);
  const E = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    L[i] = src[i * 4]! / 255;
    E[i] = src[i * 4 + 2]! / 255;
  }
  const on = new Uint8Array(n);
  if (art.mode === "atkinson") {
    const spread = [[1, 0], [2, 0], [-1, 1], [0, 1], [1, 1], [0, 2]] as const;
    for (let y = 0; y < h; y++)
      for (let x = 0; x < w; x++) {
        const i = y * w + x;
        const v = L[i]!;
        const nv = v > 0.5 ? 1 : 0;
        const er = (v - nv) / 8;
        on[i] = nv;
        for (const [qx, qy] of spread) {
          const X = x + qx;
          const Y = y + qy;
          if (X >= 0 && X < w && Y < h) L[Y * w + X] += er;
        }
      }
  } else {
    for (let y = 0; y < h; y++)
      for (let x = 0; x < w; x++) {
        const i = y * w + x;
        on[i] = L[i]! > (B8[(y % 8) * 8 + (x % 8)]! + 0.5) / 64 ? 1 : 0;
      }
  }
  for (let i = 0; i < n; i++) {
    const x = i % w;
    const y = (i / w) | 0;
    const em = E[i]! > (B8[(y % 8) * 8 + (x % 8)]! + 0.5) / 64;
    const col = em ? EMBER : on[i] ? BONE : null;
    if (col) {
      od[i * 4] = col[0];
      od[i * 4 + 1] = col[1];
      od[i * 4 + 2] = col[2];
    }
    od[i * 4 + 3] = 255;
  }
  cv.width = w;
  cv.height = h;
  cv.getContext("2d")!.putImageData(out, 0, 0);
}

export const ART: Record<string, Art> = {
  step1: {
    draw(c, W, H) {
      c.fillStyle = Lc(0.08);
      c.fillRect(0, H * 0.28, W, 26);
      c.fillStyle = Lc(0.5);
      for (const x of [W * 0.2, W * 0.3, W * 0.4]) c.fillRect(x, H * 0.28 + 8, 26, 10);
      c.fillStyle = Lc(1);
      c.fillRect(W * 0.62, H * 0.28 + 5, 22, 16);
      glow(c, W * 0.62 + 11, H * 0.28 + 13, 30, 0.8);
      c.fillStyle = vgrad(c, W * 0.62, H * 0.9, W * 0.5, Lc(0.3), Lc(0));
      c.fillRect(0, H * 0.45, W, H);
      c.fillStyle = Lc(0.75);
      c.fillRect(W * 0.5, H * 0.28 + 30, 120, 70);
      c.fillStyle = Lc(0.2);
      c.fillRect(W * 0.5 + 8, H * 0.28 + 40, 104, 6);
      c.fillRect(W * 0.5 + 8, H * 0.28 + 52, 70, 6);
    },
  },
  step2: {
    draw(c, W, H) {
      c.fillStyle = vgrad(c, W * 0.5, H * 0.5, W * 0.5, Lc(0.14), Lc(0));
      c.fillRect(0, 0, W, H);
      const s = 10;
      const x0 = W * 0.5 - 45;
      const y0 = H * 0.5 - 45;
      for (let y = 0; y < 9; y++)
        for (let x = 0; x < 9; x++) {
          const f = (x * 7 + y * 13 + x * y) % 5 < 2 || (x < 3 && y < 3) || (x > 5 && y < 3) || (x < 3 && y > 5);
          if (f) {
            c.fillStyle = Lc(1);
            c.fillRect(x0 + x * s, y0 + y * s, s - 1, s - 1);
          }
        }
      c.strokeStyle = Lc(0.6);
      c.lineWidth = 3;
      c.strokeRect(x0 - 16, y0 - 16, 122, 122);
      glow(c, x0 + 96, y0 + 96, 22, 0.9);
    },
  },
  step3: {
    draw(c, W, H) {
      c.fillStyle = vgrad(c, W * 0.5, H * 0.5, W * 0.6, Lc(0.1), Lc(0));
      c.fillRect(0, 0, W, H);
      drawCursor(c, W * 0.54, H * 0.32, 0.3, 0, false);
      drawHand(c, W * 0.46, H * 0.36, 0.36, -0.1);
      glow(c, W * 0.5, H * 0.34, 30, 1);
    },
  },
};
