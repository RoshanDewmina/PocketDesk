// The "reach" hero background: concept 21's original art (the halftone fingertip reaching for a crisp pointer,
// one ember dot where they nearly touch), from the first Reach hero (removed in 5643e9c), now full-bleed behind
// the hero and on a slow loop. DOM-free, so it runs in a worker on an OffscreenCanvas (reach-worker.ts) or, if
// that isn't available, on the page.
//
// Loop (LOOP s): the finger and the pointer drift together; at contact the ember sparks and a halftone
// shockwave runs through the whole field, the glow lingers, and they ease apart again.

import { Field, type AnyCanvas, type Rect } from "../scripts/art/field";
import { drawCursor, drawHand, glow, type Ctx } from "../scripts/art/shapes";

export type ReachLayout = { W: number; H: number; dpr: number; cx: number; cy: number; quiet: Rect[] };

export const LOOP = 7.2;
const APPROACH = 2.4;
const HOLD = 0.8;
const PART = 2.2;
/** The still frame (Reduce Motion, Save-Data): just after contact, glow on, no rings. */
export const STILL_T = APPROACH + 0.35;

const easeInOut = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

export class ReachCore {
  private S = { cx: 0, cy: 0, gap: 0, hs: 1, ha: 0, cs: 1, ca: 0, glow: 0, G1: 200, mob: false };
  private F: Field;
  private clock = 0;
  private lastLoop = -1;
  private contactT = -9;
  private sparks: { t: number; x: number; y: number; s: number }[] = [];
  private aim = { x: 0, y: 0 };
  private lean = { x: 0, y: 0 };
  private size = "";

  constructor(canvas: AnyCanvas) {
    const scene = (c: Ctx, _W: number, _H: number, t: number) => this.scene(c, t);
    // rippleTint low: the shockwave brightens the dots but stays bone; ember belongs to the contact point.
    this.F = new Field(canvas, { scene, cell: 7, cellSmall: 6, dust: 0.035, stars: 1.3, rippleWidth: 64, rippleLife: 2.4, rippleTint: 0.15 });
  }

  private scene(c: Ctx, t: number) {
    const S = this.S;
    const fl = Math.sin(t * 0.7) * 4;
    // The art leans a little toward the pointer or finger (a few px), the stars the other way (Field.parallax).
    const lx = this.lean.x * 14, ly = this.lean.y * 9;
    const hx = S.cx - (S.gap / 2) * Math.cos(S.ha) + lx;
    const hy = S.cy + fl - (S.gap / 2) * Math.sin(S.ha) + ly;
    drawCursor(c, S.cx + S.gap / 2 + lx * 0.6, S.cy + fl + S.gap * 0.04 + ly * 0.6, S.cs, S.ca, true);
    drawHand(c, hx, hy, S.hs, S.ha);
    if (S.glow > 0) glow(c, S.cx + lx * 0.8, S.cy + fl + ly * 0.8, 70 * S.hs * (0.6 + S.glow * 0.5), Math.min(1, S.glow));
    // Sparks: a ring of embers thrown out from a contact or a tap, for a moment.
    for (const sp of this.sparks) {
      const k = (t - sp.t) / 0.75;
      if (k < 0 || k >= 1) continue;
      // A tight ring: the ember stays close to the contact point.
      const reach = (22 + 70 * S.hs) * sp.s * (1 - Math.pow(1 - k, 3));
      for (let i = 0; i < 13; i++) {
        const a = i * 0.483 + 0.3;
        const d = reach * (0.7 + 0.3 * ((i * 7) % 3));
        glow(c, sp.x + Math.cos(a) * d, sp.y + Math.sin(a) * d, 10 + 9 * S.hs, 1 - k);
      }
    }
  }

  layout(L: ReachLayout) {
    const key = `${L.W}x${L.H}@${L.dpr}`;
    if (key !== this.size) {
      this.size = key;
      this.F.resize(L.W, L.H, L.dpr);
    }
    const S = this.S, W = L.W, mob = W < 640;
    S.mob = mob;
    S.cx = L.cx;
    S.cy = L.cy;
    // Big enough that the arm runs off the left edge and the pointer's window off the right.
    S.hs = mob ? 0.52 : Math.max(0.7, Math.min(1.05, (W / 1440) * 1.0));
    S.ha = mob ? -0.42 : -0.07;
    S.cs = mob ? 0.52 : S.hs * 0.74;
    S.ca = mob ? -0.16 : 0;
    S.G1 = W * (mob ? 0.22 : 0.17);
    this.F.setQuiet(L.quiet);
  }

  private contact(t: number, s: number) {
    const S = this.S;
    this.contactT = t;
    // Strength below 1 keeps the ring bone and peach; only the contact point itself turns ember.
    this.F.ripple(S.cx, S.cy, 1.3 * s, t, 760);
    this.sparks.push({ t, x: S.cx, y: S.cy, s });
  }

  /** An extra pulse from a click or tap: a bone shockwave from that point and a flash at the contact (the ember
   *  stays at the contact point). */
  pulse(x: number, y: number) {
    const t = this.clock;
    this.F.ripple(x, y, 0.9, t, 760);
    this.contactT = Math.max(this.contactT, t - 0.25);
  }

  /** Advance by dt seconds (the caller caps it) and draw. */
  tick(dt: number) {
    const S = this.S;
    const t = (this.clock += dt);
    const loop = Math.floor(t / LOOP), p = t - loop * LOOP;
    if (p < APPROACH) S.gap = S.G1 * (1 - easeInOut(p / APPROACH)) + 2;
    else if (p < APPROACH + HOLD) {
      if (this.lastLoop !== loop) {
        this.lastLoop = loop;
        this.contact(t, 1);
      }
      S.gap = 0;
    } else if (p < APPROACH + HOLD + PART) S.gap = S.G1 * easeInOut((p - APPROACH - HOLD) / PART);
    else S.gap = S.G1 * (1 + 0.06 * Math.sin((p - APPROACH - HOLD - PART) * 1.6));
    // Ember: faint while near, a flash at contact that lingers (afterglow), nothing far apart.
    const near = Math.max(0, 1 - S.gap / (S.G1 * 0.6));
    S.glow = 0.3 * near + 0.75 * Math.exp(-Math.max(0, t - this.contactT) / 0.9) * (t >= this.contactT ? 1 : 0);
    this.sparks = this.sparks.filter((sp) => t - sp.t < 0.8);
    const k = 1 - Math.exp(-dt / 0.6);
    this.lean.x += (this.aim.x - this.lean.x) * k;
    this.lean.y += (this.aim.y - this.lean.y) * k;
    this.F.parallax.x += (-this.aim.x - this.F.parallax.x) * k;
    this.F.parallax.y += (-this.aim.y - this.F.parallax.y) * k;
    this.F.draw(t);
  }

  /** One still frame: just after contact, glow on, no rings. */
  still() {
    const S = this.S;
    S.gap = 0;
    S.glow = 0.8;
    this.sparks = [];
    this.F.clearRipples();
    this.F.draw(STILL_T);
  }

  redraw(still: boolean) {
    if (still) this.still();
    else this.F.draw(this.clock);
  }

  /** Pointer or finger over the hero (x, y in CSS px; a = 0 when it leaves). */
  pointer(x: number, y: number, a: number) {
    this.F.mouse.x = x;
    this.F.mouse.y = y;
    this.F.mouse.a = a;
    this.aim = a > 0 ? { x: (x / this.F.W) * 2 - 1, y: (y / this.F.H) * 2 - 1 } : { x: 0, y: 0 };
  }
}

