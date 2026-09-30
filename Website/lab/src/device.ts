// The phone as a swappable component. A FrameSpec describes the hardware in iPhone points (portrait); the
// Phone class draws any spec, rotates it between portrait and landscape and keeps its screen content upright.
// Every variant builds its phones from the spec that frameFromQuery() returns (?frame=<id>).

import { h } from "./dom";
import { clamp, lerp } from "./ease";
import { buildHome, THUMB, type HomeRefs } from "./home";

export type FrameSpec = {
  id: string;
  name: string;
  /** Display in points, portrait. The Mac view, keyboard and Home screen are laid out in these points. */
  screen: { w: number; h: number };
  /** Body edge to display edge, points. */
  bezel: number;
  bodyRadius: number;
  screenRadius: number;
  cutout: { kind: "island"; w: number; h: number; top: number } | { kind: "none" };
  /** Side buttons: distance from the top of the body and length, points. */
  buttons: { side: "left" | "right"; top: number; len: number }[];
  /**
   * Foldables only. When set, the Phone draws a hinge crease across the display at `at` (0–1 of the
   * portrait width, vertical axis) and the variants treat `screen` as the unfolded inner display.
   */
  fold?: { axis: "vertical"; at: number; crease: number; outer?: { w: number; h: number } };
};

/** iPhone 17 Pro, approximate: 402 × 874 pt display, Dynamic Island. */
export const IPHONE_17_PRO: FrameSpec = {
  id: "iphone-17-pro",
  name: "iPhone 17 Pro",
  screen: { w: 402, h: 874 },
  bezel: 11,
  bodyRadius: 68,
  screenRadius: 57,
  cutout: { kind: "island", w: 124, h: 36, top: 11 },
  buttons: [
    { side: "left", top: 150, len: 32 },
    { side: "left", top: 214, len: 62 },
    { side: "left", top: 290, len: 62 },
    { side: "right", top: 250, len: 100 },
  ],
};

/*
 * TODO(iphone-duo): add the foldable "iPhone Duo" frame here once its exact dimensions are reported.
 *   export const IPHONE_DUO: FrameSpec = {
 *     id: "iphone-duo", name: "iPhone Duo",
 *     screen: { w: <inner display width pt>, h: <inner display height pt> },
 *     bezel: <pt>, bodyRadius: <pt>, screenRadius: <pt>,
 *     cutout: { kind: "island" | "none", ... },
 *     buttons: [...],
 *     fold: { axis: "vertical", at: 0.5, crease: <pt>, outer: { w: <cover display pt>, h: <pt> } },
 *   };
 * then register it in FRAMES below. Every variant picks it up with ?frame=iphone-duo. The Mac view,
 * zoom limits and the outline already derive from `screen`; only the Home screen (src/home.ts, drawn for
 * 402 × 874) needs a second layout if the inner display's aspect differs a lot.
 */
export const FRAMES: Record<string, FrameSpec> = { [IPHONE_17_PRO.id]: IPHONE_17_PRO };

export function frameFromQuery(): FrameSpec {
  const id = new URLSearchParams(location.search).get("frame");
  return (id && FRAMES[id]) || IPHONE_17_PRO;
}

const ROWS = [
  ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
  ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
  ["⇧", "z", "x", "c", "v", "b", "n", "m", "⌫"],
  ["123", "space", "return"],
];

export type Pose = { cx: number; cy: number; k: number; dx: number; dy: number; dz: number; rot: number; scale: number; opacity: number };

export class Phone {
  el: HTMLElement;
  scr: HTMLElement;
  content: HTMLElement;
  live: HTMLElement;
  zoom: HTMLElement;
  kb: HTMLElement;
  ptr: HTMLElement;
  contact: HTMLElement;
  touch: HTMLElement;
  fingers: HTMLElement[];
  home: HomeRefs | null = null;
  scene!: HTMLElement;
  keys: Record<string, HTMLElement> = {};
  /** 0 = portrait, 1 = landscape (island on the left); in between while rotating. */
  o = 0;
  pose: Pose = { cx: 0, cy: 0, k: 0.4, dx: 0, dy: 0, dz: 0, rot: 0, scale: 1, opacity: 1 };

  constructor(public spec: FrameSpec, opts: { home?: boolean; cls?: string } = {}) {
    const { screen, bezel } = spec;
    this.zoom = h("div", "lx-zoom");
    this.live = h("div", "lx-live", [this.zoom]);
    this.kb = h("div", "lx-kb", [h("div", "bar", ["⌘", "⌥", "⌃", "⇧", "esc", "tab", "←", "→"].map((k) => h("b", "", [k])))]);
    for (const row of ROWS) {
      const r = h("div", "row");
      for (const k of row) {
        const b = h("b", k === "space" ? "sp" : k.length > 1 || "⇧⌫".includes(k) ? "w" : "", [k === "space" ? "" : k]);
        r.append(b);
        this.keys[k] = b;
      }
      this.kb.append(r);
    }
    this.ptr = h("div", "lx-pptr", [ptrSvg()]);
    this.contact = h("div", "lx-contact");
    this.touch = h("div", "lx-touch");
    this.fingers = [h("div", "lx-finger"), h("div", "lx-finger")];
    const handle = h("div", "lx-handle", [h("i"), h("i"), h("i"), h("i"), h("i")]);
    this.content = h("div", "lx-content", [this.live, this.kb, handle, this.ptr, this.contact, this.touch, ...this.fingers]);
    if (opts.home) {
      this.home = buildHome();
      this.content.insertBefore(this.home.el, this.kb);
    }
    this.scr = h("div", "lx-pscr", [this.content]);
    Object.assign(this.scr.style, { left: `${bezel}px`, top: `${bezel}px`, width: `${screen.w}px`, height: `${screen.h}px`, borderRadius: `${spec.screenRadius}px` });
    if (spec.cutout.kind === "island") {
      const c = spec.cutout;
      const isl = h("div", "lx-isl");
      Object.assign(isl.style, { width: `${c.w}px`, height: `${c.h}px`, top: `${c.top}px`, marginLeft: `${-c.w / 2}px` });
      this.scr.append(isl);
    }
    if (spec.fold) {
      const crease = h("div", "lx-crease");
      Object.assign(crease.style, { left: `${spec.fold.at * screen.w - spec.fold.crease / 2}px`, width: `${spec.fold.crease}px` });
      this.scr.append(crease);
    }
    this.el = h("div", `lx-phone ${opts.cls ?? ""}`, [this.scr]);
    for (const b of spec.buttons) {
      const btn = h("i", "lx-btn");
      Object.assign(btn.style, { top: `${b.top}px`, height: `${b.len}px`, [b.side]: "-4px" });
      this.el.append(btn);
    }
    Object.assign(this.el.style, { width: `${this.BW}px`, height: `${this.BH}px`, borderRadius: `${spec.bodyRadius}px` });
    this.setOrient(0);
    this.setHome(0);
  }

  get W() { return this.spec.screen.w; }
  get H() { return this.spec.screen.h; }
  get BW() { return this.W + 2 * this.spec.bezel; }
  get BH() { return this.H + 2 * this.spec.bezel; }
  /** Upright content size in points for the current orientation. */
  get cw() { return lerp(this.W, this.H, this.o); }
  get ch() { return lerp(this.H, this.W, this.o); }
  get kbFrac() { return lerp(0.4, 0.5, this.o); }

  setOrient(o: number) {
    this.o = o;
    const s = this.content.style;
    s.width = `${this.cw}px`;
    s.height = `${this.ch}px`;
    s.transform = `translate(-50%,-50%) rotate(${90 * o}deg)`;
    this.kb.style.height = `${this.kbFrac * this.ch}px`;
  }

  place() {
    const p = this.pose;
    this.el.style.transform = `translate3d(${p.cx - this.BW / 2 + p.dx}px,${p.cy - this.BH / 2 + p.dy}px,${p.dz}px) scale(${p.k * p.scale}) rotate(${-90 * this.o + p.rot}deg)`;
    this.el.style.opacity = String(p.opacity);
  }

  setKb(v: number) {
    this.kb.style.transform = `translate3d(0,${(1 - v) * 104}%,0)`;
  }

  flashKey(ch: string) {
    const k = ch === " " ? this.keys.space : ch === "\n" ? this.keys.return : this.keys[ch.toLowerCase()] ?? this.keys["123"];
    if (!k) return;
    k.classList.add("hit");
    setTimeout(() => k.classList.remove("hit"), 110);
  }

  /** 0 = Home screen, 1 = the live Mac picture, grown out of the Mac card's thumbnail. */
  setHome(e: number) {
    const ls = this.live.style;
    if (!this.home) {
      ls.clipPath = "";
      ls.opacity = "1";
      return;
    }
    const T = THUMB;
    if (e >= 1) ls.clipPath = "";
    else ls.clipPath = `inset(${lerp(T.y, 0, e)}px ${lerp(this.W - T.x - T.w, 0, e)}px ${lerp(this.H - T.y - T.h, 0, e)}px ${lerp(T.x, 0, e)}px round ${lerp(T.r, 0, e)}px)`;
    ls.opacity = String(clamp(e * 4, 0, 1));
    const hs = this.home.el.style;
    hs.opacity = String(1 - clamp(e * 1.5, 0, 1));
    hs.transform = `scale(${1 + 0.06 * e})`;
    hs.visibility = e >= 1 ? "hidden" : "";
  }

  mountScene(sc: HTMLElement) {
    sc.removeAttribute("style");
    this.zoom.append(sc);
    this.scene = sc;
  }
}

export function ptrSvg() {
  const NS = "http://www.w3.org/2000/svg";
  const s = document.createElementNS(NS, "svg");
  s.setAttribute("viewBox", "-1.5 -1.5 17 23");
  const u = document.createElementNS(NS, "use");
  u.setAttribute("href", "#ptr");
  s.append(u);
  return s;
}
