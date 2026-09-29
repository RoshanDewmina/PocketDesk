// Worker side of the hero: owns the OffscreenCanvas and the frame loop (≤ 30 fps), so the page's main
// thread only handles layout, text and input. Messages: init, layout, run, still, mouse.

import { HeroCore, type HeroLayout } from "./hero-core";

type Msg =
  | { type: "init"; canvas: OffscreenCanvas; layout: HeroLayout; still: boolean }
  | { type: "layout"; layout: HeroLayout }
  | { type: "run"; on: boolean }
  | { type: "still" }
  | { type: "mouse"; x: number; y: number; a: number };

const FRAME_MS = 1000 / 30;
const scope = self as unknown as {
  requestAnimationFrame?: (cb: (t: number) => void) => number;
  postMessage: (m: unknown) => void;
  onmessage: ((e: MessageEvent<Msg>) => void) | null;
};
const nextFrame = scope.requestAnimationFrame
  ? (cb: (t: number) => void) => scope.requestAnimationFrame!(cb)
  : (cb: (t: number) => void) => setTimeout(() => cb(performance.now()), FRAME_MS) as unknown as number;

let core: HeroCore | null = null;
let running = false;
let scheduled = false;
let last = 0;

function loop(now: number) {
  scheduled = false;
  if (!running || !core) return;
  if (!last || now - last >= FRAME_MS - 2) {
    const dt = last ? Math.min(0.05, (now - last) / 1000) : 0;
    last = now;
    core.tick(dt);
  }
  scheduled = true;
  nextFrame(loop);
}

scope.onmessage = (e) => {
  const m = e.data;
  if (m.type === "init") {
    core = new HeroCore(m.canvas, (ev) => scope.postMessage(ev));
    core.layout(m.layout);
    if (m.still) core.still();
    return;
  }
  if (!core) return;
  if (m.type === "layout") {
    core.layout(m.layout);
    if (!running) core.redraw();
  } else if (m.type === "run") {
    running = m.on;
    if (running && !scheduled) {
      last = 0;
      scheduled = true;
      nextFrame(loop);
    }
  } else if (m.type === "still") {
    core.still();
  } else if (m.type === "mouse") {
    core.mouse(m.x, m.y, m.a);
  }
};
