// One demo on the page: scales a fixed logical stage to its box, owns the clock, the rig and the field,
// and runs a variant's script in a loop (or shows its still key frame under Reduce Motion).

import { Clock, type Tok } from "./clock";
import { Phone, type FrameSpec } from "./device";
import { lerp } from "./ease";
import { Field } from "./field";
import { Rig, type Pt } from "./rig";

export type Spot = { cx: number; cy: number; k: number };
export type Layout = {
  W: number;
  H: number;
  /** Mac: horizontal centre, top edge and display width, all in stage px. */
  mac: { cx: number; top: number; sw: number };
  /** Main phone centre and scale (stage px per point), portrait and landscape. */
  phone: { p: Spot; l: Spot };
  /** Optional second, larger phone (the orbit variant's split view). */
  inset?: { p: Spot; l: Spot };
  status: number;
  hud?: Pt;
};

export interface Variant {
  layout(tall: boolean): Layout;
  build(x: Instance): void;
  reset(x: Instance): void;
  run(x: Instance, tok: Tok): Promise<boolean>;
  still(x: Instance): void;
  /** Every frame, before the phones are placed. */
  frame?(x: Instance): void;
  /** Every frame, after the rig has rendered (reads layout). */
  post?(x: Instance): void;
  resized?(x: Instance): void;
}

export const MAC_W = 1.156;

export class Instance {
  clock: Clock;
  rig: Rig;
  field: Field;
  stage: HTMLElement;
  world: HTMLElement;
  macEl: HTMLElement;
  lid: HTMLElement;
  scr: HTMLElement;
  boot: HTMLCanvasElement;
  status: HTMLElement;
  links: SVGSVGElement;
  L!: Layout;
  k = 1;
  tall = false;
  tok: Tok = { dead: true };
  private spots: ((L: Layout) => { p: Spot; l: Spot } | undefined)[] = [];

  constructor(public fig: HTMLElement, public v: Variant, public spec: FrameSpec, public still: boolean) {
    const q = <T extends Element = HTMLElement>(s: string) => fig.querySelector<T>(s)!;
    this.stage = q(".lx-stage");
    this.world = q(".lx-world");
    this.macEl = q(".lx-mac");
    this.lid = q(".lx-lid");
    this.scr = q(".lx-scr");
    this.boot = q<HTMLCanvasElement>(".lx-boot");
    this.status = q(".lx-status");
    this.links = q<SVGSVGElement>(".lx-links");
    this.clock = new Clock(fig);
    this.rig = new Rig(this.clock, this.scr);
    this.field = new Field(q<HTMLCanvasElement>(".lx-field"), q<HTMLCanvasElement>(".lx-fx"), still ? null : this.clock);
    v.build(this);
    this.rig.before.push(() => this.place());
    this.rig.after.push(() => v.post?.(this));
    this.rig.onClick = (el) => {
      const p = this.stagePt(el);
      this.field.ripple(p.x, p.y);
    };
    new ResizeObserver(() => this.resize()).observe(fig);
    this.resize();
    if (still) {
      v.reset(this);
      v.still(this);
      this.rig.tick(0);
      document.fonts?.ready.then(() => this.rig.tick(0));
    } else {
      this.clock.add((dt) => this.rig.tick(dt));
      this.start();
    }
  }

  /** Add a phone. `spot` picks its place from the layout; the first phone uses layout.phone. */
  addPhone(opts: { home?: boolean; cls?: string; parent?: HTMLElement; spot?: (L: Layout) => { p: Spot; l: Spot } | undefined } = {}) {
    const ph = new Phone(this.spec, opts);
    (opts.parent ?? this.world).append(ph.el);
    this.rig.addPhone(ph);
    this.spots.push(opts.spot ?? ((L) => L.phone));
    return ph;
  }

  get phones() { return this.rig.phones; }

  start() {
    this.tok.dead = true;
    const tok = (this.tok = { dead: false });
    (async () => {
      while (!tok.dead) {
        this.v.reset(this);
        this.field.clear();
        const t0 = this.clock.time;
        if (!(await this.v.run(this, tok))) return;
        this.fig.dataset.loopMs = String(Math.round(this.clock.time - t0));
      }
    })();
  }

  replay() {
    if (!this.still) this.start();
  }

  resize() {
    const cw = this.fig.clientWidth;
    if (!cw) return;
    const contain = this.fig.dataset.fit === "contain";
    const chh = this.fig.clientHeight;
    const tall = contain ? cw / Math.max(1, chh) < 0.95 : cw < 640;
    const L = this.v.layout(tall);
    this.L = L;
    this.tall = tall;
    this.fig.toggleAttribute("data-tall", tall);
    const k = contain ? Math.min(cw / L.W, chh / L.H) : cw / L.W;
    this.k = k;
    if (!contain) this.fig.style.height = `${L.H * k}px`;
    const ox = contain ? (cw - L.W * k) / 2 : 0, oy = contain ? (chh - L.H * k) / 2 : 0;
    Object.assign(this.stage.style, { width: `${L.W}px`, height: `${L.H}px`, transform: `translate(${ox}px,${oy}px) scale(${k})` });
    const m = L.mac;
    this.macEl.style.setProperty("--sw", `${m.sw}px`);
    this.macEl.style.left = `${m.cx - (m.sw * MAC_W) / 2}px`;
    this.macEl.style.top = `${m.top}px`;
    this.rig.ms = m.sw / 800;
    this.rig.macScene.style.transform = `scale(${this.rig.ms})`;
    this.rig.macPtr.style.width = `${20 * this.rig.ms}px`;
    this.status.style.top = `${L.status}px`;
    this.links.setAttribute("viewBox", `0 0 ${L.W} ${L.H}`);
    this.links.style.width = `${L.W}px`;
    this.links.style.height = `${L.H}px`;
    const d = Math.min(2, devicePixelRatio || 1) * k;
    this.boot.width = Math.round(m.sw * d);
    this.boot.height = Math.round(m.sw * 0.625 * d);
    this.field.resize(L.W, L.H, k);
    this.v.resized?.(this);
    this.rig.tick(0);
  }

  place() {
    this.phones.forEach((ph, i) => {
      const s = this.spots[i]!(this.L);
      if (!s) return;
      const o = ph.o;
      ph.pose.cx = lerp(s.p.cx, s.l.cx, o);
      ph.pose.cy = lerp(s.p.cy, s.l.cy, o);
      ph.pose.k = lerp(s.p.k, s.l.k, o);
    });
    this.v.frame?.(this);
    for (const ph of this.phones) ph.place();
  }

  /** Centre of an element in stage coordinates (works through the 3D transforms). */
  stagePt(el: Element): Pt {
    const a = this.stage.getBoundingClientRect(), b = el.getBoundingClientRect();
    return { x: (b.left + b.width / 2 - a.left) / this.k, y: (b.top + b.height / 2 - a.top) / this.k };
  }

  /** A Mac-scene point in stage coordinates (flat Mac only). */
  macPt(mx: number, my: number): Pt {
    const a = this.stage.getBoundingClientRect(), b = this.scr.getBoundingClientRect();
    return { x: (b.left - a.left) / this.k + mx * this.rig.ms, y: (b.top - a.top) / this.k + my * this.rig.ms };
  }

  setStatus(o: number) {
    this.status.style.opacity = String(o);
  }
}
