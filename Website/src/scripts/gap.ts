// "Close the gap" (concept 21's signature moment): the halftone hand follows your mouse, trackpad or finger
// toward the Mac pointer. The first touch startles the pointer; the second connects, with the ember ripple.
// Left alone, the hand reaches by itself; "Close it for me" does it on request (keyboard, switch access).
// ≤ 30 fps on the main thread, paused off-screen and on hidden tabs. Reduce Motion, Save-Data or the pause
// switch show still frames instead: the button then flips between the open gap and the contact.

import { Field } from "./art/field";
import { drawCursor, drawHand, glow, type Ctx } from "./art/shapes";
import { motionAllowed, onMotionChange } from "./motion";

type Pt = { x: number; y: number };
type State = "reach" | "dodge" | "hit";

const LINES: Record<State, [string, string]> = {
  reach: ["Status · reaching", "Nearly there. Keep going."],
  dodge: ["Status · pointer startled", "It’s shy the first time. Try again."],
  hit: ["Status · connected", "Connected. That’s the whole product."],
};

export function initGap(root: HTMLElement) {
  const cv = root.querySelector<HTMLCanvasElement>(".gap-cv");
  const stage = root.querySelector<HTMLElement>(".gap-stage");
  const box = root.querySelector<HTMLElement>(".gap");
  const cap = root.querySelector<HTMLElement>(".gap-cap");
  const line = root.querySelector<HTMLElement>(".gap-line");
  const km = root.querySelector<HTMLElement>(".gap-km");
  const go = root.querySelector<HTMLButtonElement>(".gap-go");
  if (!cv || !stage || !box || !cap || !line || !km || !go || !cv.getContext) return;

  const G = {
    W: 1,
    H: 1,
    mob: false,
    hs: 0.8,
    ha: -0.06,
    cs: 0.6,
    glow: 0,
    tip: { x: 0, y: 0 } as Pt,
    tgt: { x: 0, y: 0 } as Pt,
    cur: { x: 0, y: 0 } as Pt,
    curTo: { x: 0, y: 0 } as Pt,
    home: { x: 0, y: 0 } as Pt,
    alt: { x: 0, y: 0 } as Pt,
    rest: { x: 0, y: 0 } as Pt,
    state: "reach" as State,
    shy: true,
    auto: false,
    idle: 0,
    lock: 0,
  };

  const scene = (c: Ctx, _W: number, _H: number, t: number) => {
    drawCursor(c, G.cur.x, G.cur.y + Math.sin(t * 0.9) * 3, G.cs, -0.04, false);
    drawHand(c, G.tip.x, G.tip.y, G.hs, G.ha);
    if (G.glow > 0) glow(c, G.cur.x, G.cur.y, 70 * G.hs + 30 * G.glow, Math.min(1, G.glow));
  };
  const F = new Field(cv, { scene, cell: 6.5, cellSmall: 6, dust: 0.04, rippleLife: 1.6 });

  function layout() {
    const r = stage!.getBoundingClientRect();
    G.W = Math.max(1, r.width);
    G.H = Math.max(1, r.height);
    G.mob = G.W < 640;
    F.resize(G.W, G.H, Math.min(2, window.devicePixelRatio || 1));
    G.hs = G.mob ? 0.42 : Math.max(0.55, Math.min(0.9, G.W / 1440));
    G.cs = G.mob ? 0.34 : G.hs * 0.72;
    G.ha = G.mob ? -0.3 : -0.06;
    G.home = { x: G.W * (G.mob ? 0.74 : 0.66), y: G.H * (G.mob ? 0.3 : 0.34) };
    G.alt = { x: G.W * (G.mob ? 0.8 : 0.8), y: G.H * (G.mob ? 0.16 : 0.2) };
    G.rest = { x: G.W * 0.34, y: G.H * (G.mob ? 0.66 : 0.62) };
    G.cur = { ...G.home };
    G.curTo = { ...G.home };
    G.tip = { ...G.rest };
    G.tgt = { ...G.rest };
  }

  let shown: State | null = null;
  function say(s: State) {
    if (s === shown) return;
    shown = s;
    cap!.textContent = LINES[s][0];
    line!.textContent = LINES[s][1];
    go!.textContent = s === "hit" ? "Open it again" : "Close it for me";
  }
  function readout(cm: number, hit: boolean) {
    const text = `${Math.max(0, Math.round(cm))} cm`;
    if (km!.textContent !== text) km!.textContent = text;
    km!.classList.toggle("hit", hit);
  }

  function connect(t: number) {
    G.state = "hit";
    G.lock = t;
    G.auto = false;
    F.ripple(G.cur.x, G.cur.y, 1.4, t, 760);
    G.glow = 1.4;
    readout(0, true);
    say("hit");
    box!.classList.remove("buzz");
    void box!.offsetWidth;
    box!.classList.add("buzz");
  }

  function reset() {
    G.state = "reach";
    G.shy = true;
    G.auto = false;
    G.curTo = { ...G.home };
    G.tgt = { ...G.rest };
    G.idle = 0;
    say("reach");
  }

  let clock = 0;
  function tick(dt: number) {
    const t = (clock += dt);
    G.idle += dt;
    if (G.state === "reach" && (G.auto || G.idle > 2.6)) {
      const k = G.auto ? 1 : Math.min(1, (G.idle - 2.6) / 2.4);
      G.tgt = { x: G.rest.x + (G.cur.x - 8 - G.rest.x) * k, y: G.rest.y + (G.cur.y + 4 - G.rest.y) * k };
    }
    const kt = 1 - Math.pow(1 - (G.auto ? 0.06 : 0.1), dt * 60);
    G.tip.x += (G.tgt.x - G.tip.x) * kt;
    G.tip.y += (G.tgt.y - G.tip.y) * kt;
    const kc = 1 - Math.pow(1 - 0.12, dt * 60);
    G.cur.x += (G.curTo.x - G.cur.x) * kc;
    G.cur.y += (G.curTo.y - G.cur.y) * kc;
    const dist = Math.hypot(G.cur.x - G.tip.x, G.cur.y - G.tip.y);
    if (G.state === "reach") {
      readout(dist / 6, false);
      if (dist < 16) {
        if (G.shy && !G.auto) {
          G.shy = false;
          G.state = "dodge";
          G.lock = t;
          G.curTo = { ...G.alt };
          G.idle = 0;
          say("dodge");
        } else connect(t);
      }
    } else if (G.state === "dodge") {
      readout(dist / 6, false);
      if (t - G.lock > 1.2) {
        G.state = "reach";
        G.idle = 0;
        say("reach");
      }
    } else {
      G.tip.x += (G.cur.x - 2 - G.tip.x) * 0.2;
      G.tip.y += (G.cur.y - G.tip.y) * 0.2;
      if (t - G.lock > 3.6) reset();
    }
    G.glow = Math.max(G.state === "hit" ? 0.5 : 0, G.glow - dt * 1.2);
    F.draw(t);
  }

  // Still frames (Reduce Motion, Save-Data, paused): the open gap or the contact, no ripple rings.
  let stillHit = true;
  function still() {
    F.clearRipples();
    if (stillHit) {
      G.cur = { ...G.home };
      G.tip = { x: G.cur.x - 6, y: G.cur.y };
      G.glow = 0.8;
      readout(0, true);
      say("hit");
    } else {
      G.cur = { ...G.home };
      G.tip = { ...G.rest };
      G.glow = 0;
      readout(Math.hypot(G.cur.x - G.tip.x, G.cur.y - G.tip.y) / 6, false);
      say("reach");
    }
    F.draw(2);
  }

  // ---- input ----
  const aim = (e: PointerEvent) => {
    const r = cv!.getBoundingClientRect();
    const x = e.clientX - r.left;
    const y = e.clientY - r.top;
    if (G.state === "reach" || G.state === "dodge") G.tgt = { x: Math.min(x, G.cur.x + 30), y };
    G.idle = 0;
    G.auto = false;
    F.mouse.x = x;
    F.mouse.y = y;
    F.mouse.a = e.pointerType === "mouse" ? 0.6 : 0;
  };
  cv.addEventListener("pointermove", aim);
  cv.addEventListener("pointerdown", aim);
  cv.addEventListener("pointerleave", () => (F.mouse.a = 0));
  go.addEventListener("click", () => {
    if (!motionAllowed()) {
      stillHit = !stillHit;
      still();
      return;
    }
    if (G.state === "hit") reset();
    else {
      G.auto = true;
      G.shy = false;
      G.curTo = { ...G.home };
      if (G.state === "dodge") G.state = "reach";
    }
  });

  // ---- when to animate ----
  let raf = 0;
  let last = 0;
  let onScreen = false;
  const frameMs = () => 1000 / (G.mob ? 24 : 30);
  const loop = (now: number) => {
    raf = 0;
    if (!running()) return;
    if (!last || now - last >= frameMs() - 2) {
      const dt = last ? Math.min(0.05, (now - last) / 1000) : 0.016;
      last = now;
      tick(dt);
    }
    raf = requestAnimationFrame(loop);
  };
  const running = () => motionAllowed() && onScreen && !document.hidden;
  function update() {
    if (running()) {
      if (!raf) {
        last = 0;
        raf = requestAnimationFrame(loop);
      }
    } else {
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      if (!motionAllowed()) still();
    }
  }

  layout();
  if (motionAllowed()) {
    say("reach");
    tick(0.016);
  } else still();
  let lastSize = "";
  new ResizeObserver(() => {
    const size = `${stage.clientWidth}x${stage.clientHeight}`;
    if (size === lastSize) return;
    lastSize = size;
    layout();
    if (motionAllowed()) {
      reset();
      tick(0.016);
    } else still();
  }).observe(stage);
  new IntersectionObserver((es) => {
    onScreen = es[es.length - 1]!.isIntersecting;
    update();
  }).observe(stage);
  document.addEventListener("visibilitychange", update);
  onMotionChange(update);
}
