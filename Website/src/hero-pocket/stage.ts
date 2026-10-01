// The home hero's demo host, cut down from the hero lab's (Website/lab/src/stage.ts on website/hero-lab). It
// fits a fixed logical stage into its box (contain, top-aligned; the box's CSS size never depends on the
// script), owns the clock, the rig and the dot field, and either loops the variant or holds its still frame.

import { Clock, type Tok } from "./clock";
import { IPHONE_17_PRO, Phone, type FrameSpec } from "./device";
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
  status: number;
};

export interface Variant {
  layout(tall: boolean): Layout;
  build(x: Instance): void;
  reset(x: Instance): void;
  run(x: Instance, tok: Tok): Promise<boolean>;
  still(x: Instance): void;
  /** Every frame, before the phones are placed. */
  frame?(x: Instance): void;
}

export const MAC_W = 1.156;

export class Instance {
  clock: Clock;
  rig: Rig;
  field: Field;
  stage: HTMLElement;
  world: HTMLElement;
  macEl: HTMLElement;
  scr: HTMLElement;
  status: HTMLElement;
  L!: Layout;
  k = 1;
  tall = false;
  tok: Tok = { dead: true };
  /** null until the first setMotion() call. */
  running: boolean | null = null;

  constructor(public fig: HTMLElement, public v: Variant, public spec: FrameSpec = IPHONE_17_PRO) {
    const q = <T extends Element = HTMLElement>(s: string) => fig.querySelector<T>(s)!;
    this.stage = q(".lx-stage");
    this.world = q(".lx-world");
    this.macEl = q(".lx-mac");
    this.scr = q(".lx-scr");
    this.status = q(".lx-status");
    this.clock = new Clock(fig);
    this.clock.hold(true);
    this.rig = new Rig(this.clock, this.scr);
    this.field = new Field(q<HTMLCanvasElement>(".lx-field"), q<HTMLCanvasElement>(".lx-fx"), this.clock);
    v.build(this);
    this.rig.before.push(() => this.place());
    this.rig.onClick = (el) => {
      const p = this.stagePt(el);
      this.field.ripple(p.x, p.y);
    };
    this.clock.add((dt) => this.rig.tick(dt));
    new ResizeObserver(() => this.resize()).observe(fig);
    this.resize();
  }

  addPhone(opts: { home?: boolean; cls?: string } = {}) {
    const ph = new Phone(this.spec, opts);
    this.world.append(ph.el);
    this.rig.addPhone(ph);
    return ph;
  }

  get phones() {
    return this.rig.phones;
  }

  /** Loop the script (true) or hold the still key frame (false: Reduce Motion, Save-Data or the pause button). */
  setMotion(on: boolean) {
    if (on === this.running) return;
    this.running = on;
    if (on) {
      this.clock.hold(false);
      this.start();
      return;
    }
    this.tok.dead = true;
    this.clock.hold(true);
    this.fig.querySelectorAll(".lx-ring").forEach((r) => r.remove());
    this.showStill();
    document.fonts?.ready.then(() => {
      if (!this.running) this.showStill();
    });
  }

  private showStill() {
    this.v.reset(this);
    this.field.clear();
    this.v.still(this);
    this.rig.tick(0);
    this.field.draw();
  }

  private start() {
    this.tok.dead = true;
    const tok = (this.tok = { dead: false });
    (async () => {
      while (!tok.dead) {
        this.v.reset(this);
        this.field.clear();
        if (!(await this.v.run(this, tok))) return;
      }
    })();
  }

  resize() {
    const cw = this.fig.clientWidth, ch = this.fig.clientHeight;
    if (!cw || !ch) return;
    const tall = cw / ch < 0.95;
    const flipped = !!this.L && tall !== this.tall;
    const L = this.v.layout(tall);
    this.L = L;
    this.tall = tall;
    this.fig.toggleAttribute("data-tall", tall);
    const k = Math.min(cw / L.W, ch / L.H);
    this.k = k;
    const ox = (cw - L.W * k) / 2, oy = 0;
    Object.assign(this.stage.style, { width: `${L.W}px`, height: `${L.H}px`, transform: `translate(${ox}px,${oy}px) scale(${k})` });
    const m = L.mac;
    this.macEl.style.setProperty("--mac-sw", `${m.sw}px`);
    this.macEl.style.left = `${m.cx - (m.sw * MAC_W) / 2}px`;
    this.macEl.style.top = `${m.top}px`;
    this.rig.ms = m.sw / 800;
    this.rig.macScene.style.transform = `scale(${this.rig.ms})`;
    this.rig.macPtr.style.width = `${20 * this.rig.ms}px`;
    this.status.style.top = `${L.status}px`;
    this.field.resize(L.W, L.H, k);
    this.rig.tick(0);
    // Crossing between the tall and wide layouts moves the devices; the script's rectangles are from the old
    // one, so start the loop (or the still frame) again.
    if (flipped && this.running) this.start();
    else if (flipped && this.running === false) this.showStill();
  }

  place() {
    const L = this.L;
    for (const ph of this.phones) {
      const s = L.phone, o = ph.o;
      ph.pose.cx = lerp(s.p.cx, s.l.cx, o);
      ph.pose.cy = lerp(s.p.cy, s.l.cy, o);
      ph.pose.k = lerp(s.p.k, s.l.k, o);
    }
    this.v.frame?.(this);
    for (const ph of this.phones) ph.place();
  }

  /** Centre of an element in stage coordinates (works through the transforms). */
  stagePt(el: Element): Pt {
    const a = this.stage.getBoundingClientRect(), b = el.getBoundingClientRect();
    return { x: (b.left + b.width / 2 - a.left) / this.k, y: (b.top + b.height / 2 - a.top) / this.k };
  }

  setStatus(o: number) {
    this.status.style.opacity = String(o);
  }
}
