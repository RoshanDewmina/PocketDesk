// Home hero host: measures the layout, runs the halftone scene in a worker (OffscreenCanvas) when the
// browser allows it, otherwise on the main thread, and keeps the distance readout and motion switch in sync.
// ≤ 30 fps; paused off-screen and on hidden tabs; Reduce Motion, Save-Data or the pause button → still frame.

import type { Rect } from "./art/field";
import { HeroCore, type HeroEvent, type HeroLayout } from "./hero-core";
import { motionAllowed, onMotionChange } from "./motion";
import { trustedScriptURL } from "./tt";

declare const __HERO_WORKER__: string;

type Msg = { type: "layout"; layout: HeroLayout } | { type: "run"; on: boolean } | { type: "still" } | { type: "mouse"; x: number; y: number; a: number };

const FRAME_MS = 1000 / 30;

function startWorker(): Worker | null {
  if (typeof Worker !== "function" || typeof OffscreenCanvas !== "function" || !("transferControlToOffscreen" in HTMLCanvasElement.prototype)) return null;
  try {
    const url = trustedScriptURL(__HERO_WORKER__);
    return new Worker(url as string, { type: "module" });
  } catch {
    return null;
  }
}

export function initHero(hero: HTMLElement) {
  let cv = hero.querySelector<HTMLCanvasElement>(".hero-cv");
  const space = hero.querySelector<HTMLElement>(".hero-space");
  const gapr = hero.querySelector<HTMLElement>(".gapr");
  const gapv = gapr?.querySelector<HTMLElement>("b") ?? null;
  if (!cv || !space || !cv.getContext) return;

  function measure(): HeroLayout {
    const hr = hero.getBoundingClientRect();
    const sp = space!.getBoundingClientRect();
    const quiet: Rect[] = [];
    const add = (r: DOMRect | { left: number; top: number; width: number; height: number }, pad: number) => {
      if (r.width && r.height) quiet.push({ x: r.left - hr.left - pad, y: r.top - hr.top - pad, w: r.width + pad * 2, h: r.height + pad * 2 });
    };
    hero.querySelectorAll<HTMLElement>(".eyebrow, .sub, .join, .consent, .note, .corner, .motion").forEach((el) => add(el.getBoundingClientRect(), 12));
    // Headline lines: horizontal extent from the text, vertical extent from the line box.
    hero.querySelectorAll<HTMLElement>(".h1 .ln").forEach((ln) => {
      const box = ln.getBoundingClientRect();
      const text = (ln.firstElementChild as HTMLElement | null)?.getBoundingClientRect() ?? box;
      add({ left: text.left, top: box.top, width: text.width, height: box.height }, 14);
    });
    return { W: hr.width, H: hr.height, dpr: Math.min(2, window.devicePixelRatio || 1), top: sp.top - hr.top, bot: sp.bottom - hr.top, quiet };
  }

  function onEvent(e: HeroEvent) {
    if (e.type === "gap") {
      if (gapv) gapv.textContent = e.text;
    } else if (e.type === "place") {
      if (!gapr) return;
      const w = gapr.offsetWidth;
      const x = Math.round(Math.max(8, Math.min(hero.clientWidth - w - 8, e.cx - w / 2)));
      gapr.style.transform = `translate(${x}px,${Math.round(e.y)}px)`;
      gapr.classList.add("on");
    } else if (e.type === "contact") {
      gapr?.classList.add("hit");
      document.dispatchEvent(new CustomEvent("farside:contact"));
    }
  }

  // ---- renderer: worker first, main thread as the fallback ----
  let send: (m: Msg) => void = () => {};

  function mainThread(canvas: HTMLCanvasElement) {
    const core = new HeroCore(canvas, onEvent);
    let raf = 0;
    let last = 0;
    let on = false;
    const loop = (now: number) => {
      raf = 0;
      if (!on) return;
      if (!last || now - last >= FRAME_MS - 2) {
        const dt = last ? Math.min(0.05, (now - last) / 1000) : 0;
        last = now;
        core.tick(dt);
      }
      raf = requestAnimationFrame(loop);
    };
    core.layout(measure());
    if (!motionAllowed()) core.still();
    send = (m) => {
      if (m.type === "layout") {
        core.layout(m.layout);
        if (!on) core.redraw();
      } else if (m.type === "run") {
        on = m.on;
        if (on && !raf) {
          last = 0;
          raf = requestAnimationFrame(loop);
        } else if (!on && raf) {
          cancelAnimationFrame(raf);
          raf = 0;
        }
      } else if (m.type === "still") core.still();
      else core.mouse(m.x, m.y, m.a);
    };
  }

  const worker = startWorker();
  if (worker) {
    const off = cv.transferControlToOffscreen();
    let alive = false;
    const fallback = () => {
      if (alive) return;
      alive = true;
      worker.terminate();
      // The transferred canvas can't be drawn from here any more: swap in a fresh one.
      const fresh = cv!.cloneNode(false) as HTMLCanvasElement;
      cv!.replaceWith(fresh);
      cv = fresh;
      mainThread(fresh);
      update();
    };
    worker.onmessage = (e: MessageEvent<HeroEvent>) => {
      alive = true;
      onEvent(e.data);
    };
    worker.onerror = fallback;
    worker.postMessage({ type: "init", canvas: off, layout: measure(), still: !motionAllowed() }, [off]);
    send = (m) => worker.postMessage(m);
    setTimeout(fallback, 2500);
  } else {
    mainThread(cv);
  }

  // ---- when to animate ----
  let onScreen = true;
  const running = () => motionAllowed() && onScreen && !document.hidden;
  function update() {
    send({ type: "run", on: running() });
  }

  hero.addEventListener("pointermove", (e) => {
    if (e.pointerType !== "mouse") return;
    const r = hero.getBoundingClientRect();
    send({ type: "mouse", x: e.clientX - r.left, y: e.clientY - r.top, a: 1 });
  });
  hero.addEventListener("pointerleave", () => send({ type: "mouse", x: -999, y: -999, a: 0 }));

  const relayout = () => send({ type: "layout", layout: measure() });
  let resizeRaf = 0;
  let lastSize = "";
  const onResize = () => {
    cancelAnimationFrame(resizeRaf);
    resizeRaf = requestAnimationFrame(() => {
      const size = `${hero.clientWidth}x${hero.clientHeight}`;
      if (size === lastSize) return;
      lastSize = size;
      relayout();
    });
  };
  if (typeof ResizeObserver === "function") new ResizeObserver(onResize).observe(hero);
  else globalThis.addEventListener("resize", onResize);
  if (typeof IntersectionObserver === "function") {
    new IntersectionObserver((entries) => {
      onScreen = entries[entries.length - 1]!.isIntersecting;
      update();
    }).observe(hero);
  }
  document.addEventListener("visibilitychange", update);
  onMotionChange(() => {
    if (!motionAllowed()) send({ type: "still" });
    update();
  });
  document.fonts?.ready.then(relayout);
  // The entrance moves the text for about a second; measure the quiet zones again once it has settled.
  setTimeout(relayout, 1500);
  update();
}
