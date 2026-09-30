// Build-time only (never deployed): draws the Open Graph art and the app icons in headless Chrome,
// using the same halftone renderer and shapes as the live hero.

import { ART, dither } from "./art/dither";
import { Field } from "./art/field";
import { drawCursor, drawHand, glow, Lc, vgrad } from "./art/shapes";

declare global {
  interface Window {
    farsideRender: {
      og(cv: HTMLCanvasElement, quiet: { x: number; y: number; w: number; h: number }[]): void;
      icon(px: number, cells: number): string;
      svg(src: string, px: number): Promise<string>;
      art(key: string): string;
    };
  }
}

function og(cv: HTMLCanvasElement, quiet: { x: number; y: number; w: number; h: number }[]) {
  const cx = 872;
  const cy = 392;
  const F = new Field(cv, {
    cell: 7,
    dust: 0.07,
    seed: 630,
    scene(c) {
      drawCursor(c, cx + 2, cy, 0.52, -0.05, true);
      drawHand(c, cx - 2, cy + 1, 0.62, -0.34);
      glow(c, cx, cy, 64, 0.85);
    },
  });
  F.resize(1200, 630, 1);
  F.setQuiet(quiet);
  // The contact beat as a still: gap closed, ember glow, no ripple (same as the Reduce Motion frame).
  F.draw(4);
}

/** Build-time art: the "How it works" dither cards and the 404 scene. Returns a PNG data URL. */
function art(key: string) {
  const cv = document.createElement("canvas");
  if (key.startsWith("art-step") || key.startsWith("art-feat")) {
    dither(cv, ART[key.replace("art-", "")]!, 360, key.startsWith("art-feat") ? 200 : 170);
    return cv.toDataURL("image/png");
  }
  // 404: the hand reaches, the pointer isn't there.
  const W = 640;
  const H = 400;
  const F = new Field(cv, {
    cell: 6,
    dust: 0.08,
    seed: 404,
    scene(c) {
      c.fillStyle = vgrad(c, W * 0.72, H * 0.4, W * 0.34, Lc(0.05), Lc(0));
      c.fillRect(0, 0, W, H);
      const s = Math.max(0.42, Math.min(0.8, W / 900));
      drawHand(c, W * 0.5, H * 0.52, s, -0.18);
      c.save();
      c.translate(W * 0.74, H * 0.26);
      c.scale(s * 0.7, s * 0.7);
      c.setLineDash([30, 22]);
      c.lineWidth = 16;
      c.strokeStyle = Lc(0.6);
      c.beginPath();
      c.moveTo(0, 0);
      c.lineTo(0, 250);
      c.lineTo(60, 196);
      c.lineTo(98, 284);
      c.lineTo(134, 268);
      c.lineTo(96, 180);
      c.lineTo(176, 180);
      c.closePath();
      c.stroke();
      c.restore();
    },
  });
  F.resize(W, H, 2);
  F.draw(2);
  return cv.toDataURL("image/webp", 0.86);
}

/** The app icon from concept 21: a halftone pointer whose tip glows ember. Returns a PNG data URL. */
function icon(px: number, cells: number) {
  const cv = document.createElement("canvas");
  cv.width = cv.height = px;
  const W = 400;
  const cell = px / cells;
  const off = document.createElement("canvas");
  off.width = off.height = cells;
  const c = off.getContext("2d", { willReadFrequently: true })!;
  c.fillStyle = "#000";
  c.fillRect(0, 0, cells, cells);
  c.save();
  c.scale(cells / W, cells / W);
  c.fillStyle = vgrad(c, W * 0.42, W * 0.36, W * 0.7, Lc(0.14), Lc(0));
  c.fillRect(0, 0, W, W);
  drawCursor(c, W * 0.36, W * 0.24, W / 560, 0, false);
  glow(c, W * 0.36, W * 0.24, W * 0.12, 1);
  c.restore();
  const d = c.getImageData(0, 0, cells, cells).data;
  const x2 = cv.getContext("2d")!;
  x2.fillStyle = "#050505";
  x2.fillRect(0, 0, px, px);
  for (let y = 0; y < cells; y++)
    for (let x = 0; x < cells; x++) {
      const i = (y * cells + x) * 4;
      const L = d[i]! / 255;
      const E = d[i + 2]! / 255;
      const r = cell * 0.5 * 1.08 * Math.sqrt(Math.max(L, E * 0.8));
      if (r < cell * 0.08) continue;
      x2.fillStyle = E > 0.4 ? "#FF5B1F" : "#EDE8DF";
      x2.beginPath();
      x2.arc((x + 0.5) * cell, (y + 0.5) * cell, r, 0, Math.PI * 2);
      x2.fill();
    }
  return cv.toDataURL("image/png");
}

/** Rasterise an SVG (the favicon) at an exact pixel size. */
function svg(src: string, px: number) {
  return new Promise<string>((resolve, reject) => {
    const img = new Image();
    img.onload = () => {
      const cv = document.createElement("canvas");
      cv.width = cv.height = px;
      const c = cv.getContext("2d")!;
      c.imageSmoothingQuality = "high";
      c.drawImage(img, 0, 0, px, px);
      resolve(cv.toDataURL("image/png"));
    };
    img.onerror = reject;
    img.src = src;
  });
}

window.farsideRender = { og, icon, svg, art };
