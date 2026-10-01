// Page side of the "reach" background: measures the hero (where the fingertip meets the pointer, which areas
// must stay free of dots), runs reach-core in a worker on an OffscreenCanvas when it can (on the page if not),
// and forwards the pointer and taps. ≤ 30 fps (24 on phones); paused off screen, on hidden tabs and by the pause
// button; Reduce Motion and Save-Data get one still frame.

import type { Rect } from "../scripts/art/field";
import { isPaused, motionAllowed, onMotionChange, prefersReduced } from "../scripts/motion";
import { reachWorkerURL } from "../scripts/tt";
import { ReachCore, type ReachLayout } from "./reach-core";

type Msg =
  | { type: "init"; canvas: OffscreenCanvas; layout: ReachLayout; still: boolean; fps: number }
  | { type: "layout"; layout: ReachLayout }
  | { type: "run"; on: boolean }
  | { type: "still" }
  | { type: "pointer"; x: number; y: number; a: number }
  | { type: "pulse"; x: number; y: number };

/** Text and controls the dots stay out from behind (the old hero's "quiet" zones). */
const QUIET = [".hero .eyebrow", ".hero .sub", ".hero .join", ".hero .consent", ".hero .note", ".hero .motion", ".site-header .brand", ".site-header .nav-desk", ".site-header .status", ".site-header .pill", ".site-header .nav-mob"];

export function startReach(bg: HTMLElement) {
  const hero = bg.closest<HTMLElement>(".hero");
  const cv = bg.querySelector<HTMLCanvasElement>("canvas");
  if (!hero || !cv || !cv.getContext) return;
  const fps = window.innerWidth < 640 ? 24 : 30;

  function measure(): ReachLayout {
    const hr = hero!.getBoundingClientRect();
    const quiet: Rect[] = [];
    const add = (r: { left: number; top: number; width: number; height: number }, pad: number) => {
      if (r.width && r.height) quiet.push({ x: r.left - hr.left - pad, y: r.top - hr.top - pad, w: r.width + pad * 2, h: r.height + pad * 2 });
    };
    for (const s of QUIET) document.querySelectorAll<HTMLElement>(s).forEach((el) => add(el.getBoundingClientRect(), 10));
    // Headline lines: horizontal extent from the text, vertical from the line box.
    hero!.querySelectorAll<HTMLElement>(".h1 .ln").forEach((ln) => {
      const box = ln.getBoundingClientRect();
      const text = (ln.firstElementChild as HTMLElement | null)?.getBoundingClientRect() ?? box;
      add({ left: text.left, top: box.top, width: text.width, height: box.height }, 12);
    });
    // The fingertip meets the pointer just above the MacBook's top edge, between the sign-up and the demo. The Mac's place
    // comes from the demo's fixed stage layout (src/hero-pocket/pocket.ts), not its live rect, which the demo's
    // camera moves around while it plays.
    const wl = hero!.querySelector<HTMLElement>(".hero .wl")?.getBoundingClientRect();
    const box = hero!.querySelector<HTMLElement>(".hero-demo")?.getBoundingClientRect();
    let macX = hr.left + hr.width / 2, macTop = (wl ? wl.bottom : hr.top + hr.height * 0.45) + 60;
    if (box && box.width && box.height) {
      const tall = box.width / box.height < 0.95;
      // Stage x where they meet: right of the MacBook and above the phone on wide screens, so the pointer shows
      // in the free corner; a little right of the Mac's centre on phones.
      const [SW, SH, MX, MY] = tall ? [600, 880, 340, 40] : [1000, 640, 790, 56];
      const k = Math.min(box.width / SW, box.height / SH);
      macX = box.left + (box.width - SW * k) / 2 + MX * k;
      macTop = box.top + MY * k;
    }
    const textBottom = wl ? wl.bottom : macTop - 60;
    const cx = macX - hr.left;
    const cy = (textBottom + macTop) / 2 - hr.top;
    return { W: hr.width, H: hr.height, dpr: Math.min(2, window.devicePixelRatio || 1), cx, cy, quiet };
  }

  // ---- renderer: worker first, the page as the fallback ----
  let send: (m: Msg) => void = () => {};
  const shown = () => bg.classList.add("bg-on");

  function onPage(canvas: HTMLCanvasElement) {
    const core = new ReachCore(canvas);
    let raf = 0, last = 0, on = false, still = false;
    const loop = (now: number) => {
      raf = 0;
      if (!on) return;
      if (!last || now - last >= 1000 / fps - 2) {
        core.tick(last ? Math.min(0.05, (now - last) / 1000) : 0);
        last = now;
        shown();
      }
      raf = requestAnimationFrame(loop);
    };
    core.layout(measure());
    send = (m) => {
      if (m.type === "layout") {
        core.layout(m.layout);
        if (!on) core.redraw(still);
      } else if (m.type === "run") {
        on = m.on;
        if (on) still = false;
        if (on && !raf) {
          last = 0;
          raf = requestAnimationFrame(loop);
        } else if (!on && raf) {
          cancelAnimationFrame(raf);
          raf = 0;
        }
      } else if (m.type === "still") {
        still = true;
        core.still();
        shown();
      } else if (m.type === "pointer") core.pointer(m.x, m.y, m.a);
      else if (m.type === "pulse") core.pulse(m.x, m.y);
    };
  }

  let allowed = motionAllowed();
  let worker: Worker | null = null;
  if (typeof Worker === "function" && typeof OffscreenCanvas === "function" && "transferControlToOffscreen" in HTMLCanvasElement.prototype) {
    try {
      worker = new Worker(reachWorkerURL(), { type: "module" });
    } catch {
      worker = null;
    }
  }
  if (worker) {
    const w = worker;
    const off = cv.transferControlToOffscreen();
    let alive = false;
    const fallback = () => {
      if (alive) return;
      alive = true;
      w.terminate();
      // The transferred canvas can't be drawn from here any more: swap in a fresh one.
      const fresh = cv.cloneNode(false) as HTMLCanvasElement;
      cv.replaceWith(fresh);
      onPage(fresh);
      if (!allowed) send({ type: "still" });
      update();
    };
    w.onmessage = (e: MessageEvent<{ type: string }>) => {
      alive = true;
      if (e.data.type === "drawn") shown();
    };
    w.onerror = fallback;
    w.postMessage({ type: "init", canvas: off, layout: measure(), still: !allowed, fps } satisfies Msg, [off]);
    send = (m) => w.postMessage(m);
    setTimeout(fallback, 3000);
  } else {
    onPage(cv);
    if (!allowed) send({ type: "still" });
  }

  // ---- when to animate ----
  let onScreen = true;
  const update = () => send({ type: "run", on: allowed && onScreen && !document.hidden });

  hero.addEventListener("pointermove", (e) => {
    const r = hero.getBoundingClientRect();
    send({ type: "pointer", x: e.clientX - r.left, y: e.clientY - r.top, a: 1 });
  });
  hero.addEventListener("pointerleave", () => send({ type: "pointer", x: -999, y: -999, a: 0 }));
  // A click or tap anywhere in the hero that isn't on a control sends an extra contact pulse.
  hero.addEventListener("click", (e) => {
    if (!allowed || (e.target as Element).closest("a, button, input, label, form, .hero-demo")) return;
    const r = hero.getBoundingClientRect();
    send({ type: "pulse", x: e.clientX - r.left, y: e.clientY - r.top });
  });

  let resizeRaf = 0, lastSize = "";
  const relayout = () => send({ type: "layout", layout: measure() });
  new ResizeObserver(() => {
    cancelAnimationFrame(resizeRaf);
    resizeRaf = requestAnimationFrame(() => {
      const size = `${hero.clientWidth}x${hero.clientHeight}`;
      if (size === lastSize) return;
      lastSize = size;
      relayout();
    });
  }).observe(hero);
  new IntersectionObserver((es) => {
    onScreen = es[es.length - 1]!.isIntersecting;
    update();
  }).observe(hero);
  document.addEventListener("visibilitychange", update);
  // Cached and refreshed here only: reading matchMedia().matches every frame would swallow its change event.
  onMotionChange(() => {
    allowed = motionAllowed();
    if (prefersReduced() && !isPaused()) send({ type: "still" });
    update();
  });
  // The demo places the MacBook once it starts; measure again then, and after the entrance has settled.
  setTimeout(relayout, 400);
  setTimeout(relayout, 1600);
  update();
}
