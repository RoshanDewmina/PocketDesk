// The hero's scene and timeline (concept 21 · Reach), free of the DOM so it can run in a worker on an
// OffscreenCanvas. The page sends layout, visibility and pointer updates; the core sends back the text
// for the distance readout and the contact moment.

import { Field, type AnyCanvas, type Rect } from "./art/field";
import { drawCursor, drawHand, easeInOut, easeOutExpo, glow, type Ctx } from "./art/shapes";

export type HeroLayout = { W: number; H: number; dpr: number; top: number; bot: number; quiet: Rect[] };
export type HeroEvent = { type: "gap"; text: string } | { type: "contact" } | { type: "place"; cx: number; y: number };

const CLOSE_S = 1.15;
const LOOP_S = 5.6;
const CONNECTED = "0 km · connected";

export class HeroCore {
  private S = { cx: 0, cy: 0, gap: 0, hs: 1, ha: 0, cs: 1, ca: 0, glow: 0, G0: 600, mob: false };
  private F: Field;
  private clock = 0;
  private touched = false;
  private lastTap = 0;
  private clickUntil = 0;
  private km = "";
  private size = "";
  private isStill = false;

  constructor(
    canvas: AnyCanvas,
    private emit: (e: HeroEvent) => void,
  ) {
    const scene = (c: Ctx, _W: number, _H: number, t: number) => this.scene(c, t);
    this.F = new Field(canvas, { scene, cell: 7, cellSmall: 5, dust: 0.07 });
  }

  private scene(c: Ctx, t: number) {
    const S = this.S;
    const fl = Math.sin(t * 0.7) * 4;
    const hx = S.cx - (S.gap / 2) * Math.cos(S.ha);
    const hy = S.cy + fl - (S.gap / 2) * Math.sin(S.ha);
    drawCursor(c, S.cx + S.gap / 2, S.cy + fl + S.gap * 0.04, S.cs, S.ca, true);
    drawHand(c, hx, hy, S.hs, S.ha);
    if (S.glow > 0) glow(c, S.cx, S.cy + fl, 90 * S.hs * (0.6 + S.glow * 0.6), Math.min(1, S.glow));
  }

  layout(L: HeroLayout) {
    const key = `${L.W}x${L.H}@${L.dpr}`;
    if (key !== this.size) {
      this.size = key;
      this.F.resize(L.W, L.H, L.dpr);
    }
    const S = this.S;
    const W = L.W;
    const mob = W < 640;
    S.mob = mob;
    S.hs = mob ? 0.5 : Math.max(0.6, Math.min(1, (W / 1440) * 0.9));
    S.cy = mob ? Math.max(L.top + 80, Math.min(L.bot - 150, (L.top + L.bot) / 2)) : Math.max(L.top + 90, Math.min(L.bot - 200 * S.hs, L.top + 130));
    S.cx = W * (mob ? 0.46 : 0.5);
    S.ha = mob ? -0.46 : -0.08;
    S.cs = mob ? 0.42 : S.hs * 0.74;
    S.ca = mob ? -0.18 : 0;
    S.G0 = W * (mob ? 0.9 : 0.62);
    this.F.setQuiet(L.quiet);
    this.emit({ type: "place", cx: S.cx, y: Math.max(L.top + 10, S.cy - (mob ? 74 : 86)) });
  }

  private setGap(text: string) {
    if (text !== this.km) this.emit({ type: "gap", text: (this.km = text) });
  }

  // Thousands separator by hand: the first Intl/toLocaleString call can cost tens of ms on a phone.
  private kmFor(g: number) {
    const k = Math.round(8421 * Math.pow(Math.max(0, g) / this.S.G0, 1.35));
    return k > 0 ? `${String(k).replace(/\B(?=(\d{3})+(?!\d))/g, ",")} km` : "0 km";
  }

  private contact(t: number) {
    this.touched = true;
    this.lastTap = t;
    this.F.ripple(this.S.cx, this.S.cy, 1.5, t, 820);
    this.setGap(CONNECTED);
    this.emit({ type: "contact" });
  }

  /** Advance the timeline by dt seconds (capped by the caller) and draw. */
  tick(dt: number) {
    this.isStill = false;
    const S = this.S;
    const t = (this.clock += dt);
    if (t < CLOSE_S) {
      S.gap = S.G0 * (1 - easeOutExpo(t / CLOSE_S)) + 4;
      S.glow = 0;
      this.setGap(this.kmFor(S.gap - 4));
    } else {
      if (!this.touched) this.contact(t);
      const p = (t - CLOSE_S) % LOOP_S;
      let g = 0;
      if (p > 3.9 && p < 4.7) g = 30 * easeOutExpo((p - 3.9) / 0.8);
      else if (p >= 4.7 && p < 5.15) g = 30 * (1 - easeInOut((p - 4.7) / 0.45));
      S.gap = g;
      if (p >= 5.15 && t - this.lastTap > 2) {
        this.lastTap = t;
        this.F.ripple(S.cx, S.cy, 0.75, t, 700);
        this.setGap("click.");
        this.clickUntil = t + 0.9;
      } else if (this.clickUntil && t > this.clickUntil) {
        this.clickUntil = 0;
        this.setGap(CONNECTED);
      }
      S.glow = 0.45 + 0.8 * Math.max(0, 1 - (t - this.lastTap) / 0.9);
    }
    this.F.draw(t);
  }

  /** The contact beat as one frame: gap closed, ember glow on, no ripple rings (Reduce Motion, pause). */
  still() {
    this.isStill = true;
    if (this.clock < CLOSE_S) this.clock = CLOSE_S;
    if (!this.touched) {
      this.touched = true;
      this.emit({ type: "contact" });
    }
    this.lastTap = this.clock;
    this.clickUntil = 0;
    this.S.gap = 0;
    this.S.glow = 0.6;
    this.F.clearRipples();
    this.setGap(CONNECTED);
    this.F.draw(this.clock + 3);
  }

  /** Repaint the current state (after a resize while paused or off-screen). */
  redraw() {
    if (this.isStill) this.still();
    else this.F.draw(this.clock);
  }

  mouse(x: number, y: number, a: number) {
    this.F.mouse.x = x;
    this.F.mouse.y = y;
    this.F.mouse.a = a;
  }
}
