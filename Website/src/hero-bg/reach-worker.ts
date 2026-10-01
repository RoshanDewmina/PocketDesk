// Worker side of the reach background: owns the OffscreenCanvas and the frame loop, so the page's main thread
// only measures the layout and forwards the pointer. Messages: init, layout, run, still, pointer, pulse.

import { ReachCore, type ReachLayout } from "./reach-core";

type Msg =
  | { type: "init"; canvas: OffscreenCanvas; layout: ReachLayout; still: boolean; fps: number }
  | { type: "layout"; layout: ReachLayout }
  | { type: "run"; on: boolean }
  | { type: "still" }
  | { type: "pointer"; x: number; y: number; a: number }
  | { type: "pulse"; x: number; y: number };

const scope = self as unknown as {
  requestAnimationFrame?: (cb: (t: number) => void) => number;
  postMessage: (m: unknown) => void;
  onmessage: ((e: MessageEvent<Msg>) => void) | null;
};

let core: ReachCore | null = null;
let frameMs = 1000 / 30;
let running = false, scheduled = false, last = 0, isStill = false, drawn = false;

const nextFrame = (cb: (t: number) => void) =>
  scope.requestAnimationFrame ? scope.requestAnimationFrame(cb) : (setTimeout(() => cb(performance.now()), frameMs) as unknown as number);

function told() {
  if (drawn) return;
  drawn = true;
  scope.postMessage({ type: "drawn" });
}

function loop(now: number) {
  scheduled = false;
  if (!running || !core) return;
  if (!last || now - last >= frameMs - 2) {
    core.tick(last ? Math.min(0.05, (now - last) / 1000) : 0);
    last = now;
    told();
  }
  scheduled = true;
  nextFrame(loop);
}

scope.onmessage = (e) => {
  const m = e.data;
  if (m.type === "init") {
    frameMs = 1000 / m.fps;
    core = new ReachCore(m.canvas);
    core.layout(m.layout);
    isStill = m.still;
    if (isStill) {
      core.still();
      told();
    }
    return;
  }
  if (!core) return;
  if (m.type === "layout") {
    core.layout(m.layout);
    if (!running) core.redraw(isStill);
  } else if (m.type === "run") {
    running = m.on;
    if (running) isStill = false;
    if (running && !scheduled) {
      last = 0;
      scheduled = true;
      nextFrame(loop);
    }
  } else if (m.type === "still") {
    isStill = true;
    core.still();
    told();
  } else if (m.type === "pointer") core.pointer(m.x, m.y, m.a);
  else if (m.type === "pulse") core.pulse(m.x, m.y);
};
