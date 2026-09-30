// The Mac-and-phone rig every variant drives: one Mac scene (A2's markup), a copy of it inside each phone,
// the pointer, the camera and the ember outline of the region the phone is showing.
//
// Units: the Mac scene is 800 × 500 "Mac units". Phone content is in iPhone points. z = points per Mac unit.
// Camera behaviour follows PRODUCT.md D34 ("Smooth"): the pointer is drawn 1:1 with the finger; only when it
// comes near an edge does the view ease after it, settling in about 0.2 s.

import type { Clock, Tok } from "./clock";
import type { Phone } from "./device";
import { EASE, IO, clamp, lerp, type Ease } from "./ease";

export const DW = 800;
export const DH = 500;
export type Pt = { x: number; y: number };
export type Rect = { x: number; y: number; w: number; h: number };
export type Seg = [string, string];
export type Line = Seg[];
type Finger = { x: number; y: number; o: number; down: boolean };

const APP: Record<string, string> = { chat: "Chat", mus: "Player", term: "Terminal", fnd: "Finder" };
const MX = 0.2, MY = 0.26, TAU = 50;
const FLAGS = ["typing", "sent", "paused", "nx", "dlg", "zip"];

export const lerpRect = (a: Rect, b: Rect, e: number): Rect => ({ x: lerp(a.x, b.x, e), y: lerp(a.y, b.y, e), w: lerp(a.w, b.w, e), h: lerp(a.h, b.h, e) });

export class Rig {
  macScene: HTMLElement;
  scenes: HTMLElement[];
  phones: Phone[] = [];
  P: Pt = { x: 400, y: 250 };
  C: Pt = { x: 0, y: 0 };
  z = 1.75;
  follow = true;
  /** True while the view is still easing after the pointer (the D34 moment). */
  following = false;
  kb = 0;
  ms = 0.7;
  F: Finger[] = [{ x: 0, y: 0, o: 0, down: false }, { x: 0, y: 0, o: 0, down: false }];
  contactO = 0;
  touchO = 0;
  touchAt: Pt = { x: 0, y: 0 };
  ptrO = 1;
  outlineO = 1;
  lock = 0;
  outlineRect: Rect | null = null;
  outline: HTMLElement;
  macPtr: HTMLElement;
  before: (() => void)[] = [];
  after: (() => void)[] = [];
  onClick: ((el: Element) => void) | null = null;
  private sticky: Tok = { dead: false };

  constructor(public clock: Clock, public macScr: HTMLElement) {
    this.macScene = macScr.querySelector<HTMLElement>(".a2-scene")!;
    this.scenes = [this.macScene];
    this.outline = macScr.querySelector<HTMLElement>(".lx-view")!;
    this.macPtr = macScr.querySelector<HTMLElement>(".lx-mptr")!;
  }

  addPhone(p: Phone) {
    p.mountScene(this.macScene.cloneNode(true) as HTMLElement);
    this.phones.push(p);
    this.scenes.push(p.scene);
  }

  get ph() { return this.phones[0]!; }
  get cw() { return this.ph.cw; }
  get ch() { return this.ph.ch; }
  get chE() { return this.ch * (1 - this.ph.kbFrac * this.kb); }
  get vw() { return this.cw / this.z; }
  get vh() { return this.chE / this.z; }
  /** Smallest zoom that still fills the phone with Mac (the "Fill" picture). */
  minZ() { return Math.max(this.cw / DW, this.ch / DH); }

  clampCam() {
    this.C.x = clamp(this.C.x, 0, Math.max(0, DW - this.vw));
    this.C.y = clamp(this.C.y, 0, Math.max(0, DH - this.vh));
  }

  camTarget(): Pt {
    let { x, y } = this.C;
    const vw = this.vw, vh = this.vh, mx = vw * MX, my = vh * MY, P = this.P;
    if (P.x < x + mx) x = P.x - mx;
    else if (P.x > x + vw - mx) x = P.x - vw + mx;
    if (P.y < y + my) y = P.y - my;
    else if (P.y > y + vh - my) y = P.y - vh + my;
    return { x: clamp(x, 0, Math.max(0, DW - vw)), y: clamp(y, 0, Math.max(0, DH - vh)) };
  }

  /** Put the camera where it would have settled, with no easing. */
  settle() {
    const t = this.camTarget();
    this.C = t;
    this.clampCam();
  }

  tick(dt: number) {
    for (const f of this.before) f();
    if (this.follow) {
      const t = this.camTarget(), k = 1 - Math.exp(-dt / TAU), dx = t.x - this.C.x, dy = t.y - this.C.y;
      this.C.x += dx * k;
      this.C.y += dy * k;
      const vw = this.vw, vh = this.vh;
      this.C.x = clamp(this.C.x, Math.min(DW - vw, Math.max(0, this.P.x - vw + 6)), Math.max(0, Math.min(DW - vw, this.P.x - 2)));
      this.C.y = clamp(this.C.y, Math.min(DH - vh, Math.max(0, this.P.y - vh + 8)), Math.max(0, Math.min(DH - vh, this.P.y - 2)));
      this.following = Math.hypot(dx, dy) > 0.35;
    } else this.following = false;
    this.clampCam();
    this.render();
    for (const f of this.after) f();
  }

  render() {
    const { ms, C, P, z } = this;
    const r = this.outlineRect ?? { x: C.x, y: C.y, w: this.vw, h: this.vh };
    const os = this.outline.style;
    os.transform = `translate(${r.x * ms}px,${r.y * ms}px)`;
    os.width = `${r.w * ms}px`;
    os.height = `${r.h * ms}px`;
    os.opacity = String(this.outlineO);
    os.setProperty("--lock", String(this.lock));
    this.macPtr.style.transform = `translate(${P.x * ms}px,${P.y * ms}px)`;
    this.macPtr.style.opacity = String(this.ptrO);
    for (const ph of this.phones) {
      ph.zoom.style.transform = `translate(${-C.x * z}px,${-C.y * z}px) scale(${z})`;
      const q = `translate(${(P.x - C.x) * z}px,${(P.y - C.y) * z}px)`;
      ph.ptr.style.transform = q;
      ph.ptr.style.opacity = String(this.ptrO);
      ph.contact.style.transform = q;
      ph.contact.style.opacity = String(this.contactO);
      ph.touch.style.transform = `translate(${this.touchAt.x}px,${this.touchAt.y}px)`;
      ph.touch.style.opacity = String(this.touchO);
      this.F.forEach((f, i) => {
        const g = ph.fingers[i]!.style;
        g.transform = `translate(${f.x}px,${f.y}px) scale(${f.down ? 0.84 : 1})`;
        g.opacity = String(f.o);
      });
      ph.setKb(this.kb);
    }
  }

  // ---------- the Mac's state, mirrored into every copy ----------

  each(fn: (sc: HTMLElement) => void) {
    this.scenes.forEach(fn);
  }

  resetScene() {
    this.each((sc) => {
      for (const f of FLAGS) sc.classList.remove(f);
      sc.querySelectorAll<HTMLElement>("[data-w]").forEach((el) => (el.style.translate = ""));
      sc.querySelectorAll(".fi.sel").forEach((el) => el.classList.remove("sel"));
    });
    this.chatText("");
    this.focus("chat");
    this.kb = 0;
    this.F.forEach((f) => Object.assign(f, { o: 0, down: false }));
    this.contactO = this.touchO = 0;
    this.lock = 0;
    this.outlineRect = null;
    this.follow = true;
    this.sticky.dead = true;
    this.sticky = { dead: false };
  }

  focus(w: string) {
    this.each((sc) => {
      sc.querySelectorAll<HTMLElement>("[data-w]").forEach((el) => el.classList.toggle("on", el.dataset.w === w));
      sc.querySelector(".app")!.textContent = APP[w] ?? "Finder";
    });
  }

  flag(c: string, on: boolean) {
    this.each((sc) => sc.classList.toggle(c, on));
  }

  chatText(s: string) {
    this.each((sc) => {
      sc.querySelector(".ch-in .tx")!.textContent = s;
      (sc.querySelector(".ch-in .ph") as HTMLElement).style.display = s ? "none" : "";
    });
  }

  setTerm(lines: Line[], cursor = true) {
    this.each((sc) => {
      const pre = sc.querySelector(".s-tt")!;
      pre.replaceChildren();
      lines.forEach((ln, i) => {
        if (i) pre.append("\n");
        for (const [c, t] of ln) {
          if (!c) {
            pre.append(t);
            continue;
          }
          const s = document.createElement("span");
          s.className = c;
          s.textContent = t;
          pre.append(s);
        }
      });
      if (cursor) {
        const cr = document.createElement("span");
        cr.className = "s-cr";
        pre.append(cr);
      }
    });
  }

  moveWin(w: string, dx: number, dy: number) {
    this.each((sc) => {
      sc.querySelector<HTMLElement>(`[data-w=${w}]`)!.style.translate = `${dx}px ${dy}px`;
    });
  }

  select(sel: string, on: boolean) {
    this.each((sc) => sc.querySelector(sel)?.classList.toggle("sel", on));
  }

  rect(sel: string): Rect {
    let el = this.macScene.querySelector<HTMLElement>(sel)!;
    const w = el.offsetWidth, h = el.offsetHeight;
    let x = 0, y = 0;
    while (el && el !== this.macScene) {
      x += el.offsetLeft;
      y += el.offsetTop;
      el = el.offsetParent as HTMLElement;
    }
    return { x, y, w, h };
  }

  ctr(sel: string, fx = 0.5, fy = 0.5): Pt {
    const r = this.rect(sel);
    return { x: r.x + r.w * fx, y: r.y + r.h * fy };
  }

  // ---------- the finger on the glass ----------

  private get fw() { return this.cw; }
  private get fh() { return this.chE; }

  fade(i: number, to: number, ms: number, tok: Tok) {
    const f = this.F[i]!, from = f.o;
    return this.clock.tween(ms, (e) => (f.o = lerp(from, to, e)), tok, IO);
  }

  glide(to: Pt, ms: number, tok: Tok, each?: (e: number) => void, ease: Ease = IO) {
    const p0 = { ...this.P }, f0 = { x: this.F[0]!.x, y: this.F[0]!.y }, z = this.z;
    return this.clock.tween(ms, (e) => {
      this.P.x = lerp(p0.x, to.x, e);
      this.P.y = lerp(p0.y, to.y, e);
      this.F[0]!.x = f0.x + (this.P.x - p0.x) * z;
      this.F[0]!.y = f0.y + (this.P.y - p0.y) * z;
      each?.(e);
    }, tok, ease);
  }

  /** Drag the pointer to a Mac point like a trackpad: lift and re-place the finger when it would run off the glass. */
  async travel(to: Pt, tok: Tok, slow = 1, each?: (e: number) => void) {
    const s = this.z, pw = this.fw, ph = this.fh, F = this.F[0]!;
    const dx = (to.x - this.P.x) * s, dy = (to.y - this.P.y) * s;
    const parts = Math.max(1, Math.ceil(Math.abs(dx) / (pw * 0.6)), Math.ceil(Math.abs(dy) / (ph * 0.62)));
    for (let i = 0; i < parts; i++) {
      const tgt = { x: this.P.x + (to.x - this.P.x) / (parts - i), y: this.P.y + (to.y - this.P.y) / (parts - i) };
      const fdx = (tgt.x - this.P.x) * s, fdy = (tgt.y - this.P.y) * s;
      const vis = F.o >= 0.05;
      const fits = (x: number, y: number) => x > pw * 0.08 && x < pw * 0.92 && y > ph * 0.12 && y < ph * 0.9;
      let sx = clamp(pw * 0.5 - fdx / 2, pw * 0.1, pw * 0.9), sy = clamp(ph * 0.55 - fdy / 2, ph * 0.16, ph * 0.86);
      if (vis && fits(F.x + fdx, F.y + fdy)) {
        sx = F.x;
        sy = F.y;
      }
      if (!vis) {
        F.x = sx;
        F.y = sy;
        if (!(await this.fade(0, 1, 220, tok))) return false;
        if (!(await this.clock.wait(90, tok))) return false;
      } else if (Math.hypot(sx - F.x, sy - F.y) > 4) {
        const g0 = { x: F.x, y: F.y }, o0 = F.o;
        if (!(await this.clock.tween(240, (e) => {
          F.x = lerp(g0.x, sx, e);
          F.y = lerp(g0.y, sy, e);
          F.o = Math.max(0.25, o0 - Math.sin(Math.PI * e) * 0.7);
        }, tok))) return false;
        F.o = 1;
      } else F.o = 1;
      if (!(await this.glide(tgt, clamp(260 + Math.hypot(fdx, fdy) * 1.5, 420, 760) * slow, tok, each))) return false;
    }
    return true;
  }

  /** Lift the finger and put it down somewhere else on the glass (the pointer stays). */
  async regrip(to: Pt, tok: Tok) {
    const F = this.F[0]!, g0 = { x: F.x, y: F.y }, o0 = F.o;
    if (o0 < 0.05) {
      F.x = to.x;
      F.y = to.y;
      return this.fade(0, 1, 200, tok);
    }
    const ok = await this.clock.tween(260, (e) => {
      F.x = lerp(g0.x, to.x, e);
      F.y = lerp(g0.y, to.y, e);
      F.o = Math.max(0.25, o0 - Math.sin(Math.PI * e) * 0.7);
    }, tok);
    F.o = 1;
    return ok;
  }

  /** Press and hold: the ember contact stays on at the pointer tip until release(). */
  hold(tok: Tok) {
    this.F[0]!.down = true;
    return this.clock.tween(90, (e) => (this.contactO = e), tok);
  }

  release(tok: Tok) {
    this.F[0]!.down = false;
    return this.clock.tween(260, (e) => (this.contactO = 1 - e), tok);
  }

  /** A tap with the finger already resting: press, release, click at the pointer. */
  async tap(tok: Tok) {
    const F = this.F[0]!;
    F.o = 1;
    F.down = true;
    if (!(await this.clock.wait(110, tok))) return false;
    F.down = false;
    this.click();
    return true;
  }

  click() {
    this.flash("contactO");
    const q = { x: (this.P.x - this.C.x) * this.z, y: (this.P.y - this.C.y) * this.z };
    for (const ph of this.phones) this.ring(ph.content, q.x, q.y, 1.5);
    this.ring(this.macScr, this.P.x * this.ms, this.P.y * this.ms, 1.7, "m");
    this.onClick?.(this.ph.contact);
  }

  /** A direct touch on the phone's own UI (Home screen): the finger arrives, presses, an ember dot marks the contact. */
  async touch(at: Pt, from: Pt, tok: Tok) {
    const F = this.F[0]!;
    F.x = from.x;
    F.y = from.y;
    if (!(await this.fade(0, 1, 200, tok))) return false;
    const f0 = { ...from };
    if (!(await this.clock.tween(460, (e) => {
      F.x = lerp(f0.x, at.x, e);
      F.y = lerp(f0.y, at.y, e);
    }, tok, EASE))) return false;
    F.down = true;
    if (!(await this.clock.wait(120, tok))) return false;
    F.down = false;
    this.touchAt = { ...at };
    this.render();
    this.flash("touchO");
    for (const ph of this.phones) this.ring(ph.content, at.x, at.y, 1.8);
    this.onClick?.(this.ph.touch);
    return true;
  }

  private flash(key: "contactO" | "touchO") {
    const tok = this.sticky;
    this.clock.tween(90, (e) => (this[key] = e), tok, IO).then((ok) => {
      if (!ok) return;
      this.clock.wait(170, tok).then((ok2) => {
        if (ok2) this.clock.tween(340, (e) => (this[key] = 1 - e), tok, IO);
      });
    });
  }

  ring(parent: HTMLElement, x: number, y: number, sc: number, cls = "") {
    const r = document.createElement("i");
    r.className = `lx-ring ${cls}`;
    parent.append(r);
    const tok = this.sticky;
    this.clock.tween(640, (e) => {
      r.style.transform = `translate(${x}px,${y}px) scale(${0.3 + e * (sc - 0.3)})`;
      r.style.opacity = String(1 - e);
    }, tok, EASE).then(() => r.remove());
  }

  /** Two-finger pinch around the pointer; the outline on the Mac shrinks or grows with it. */
  async pinch(zTo: number, ms: number, tok: Tok) {
    const z0 = this.z;
    zTo = Math.max(zTo, this.minZ());
    const f = { x: (this.P.x - this.C.x) * z0, y: (this.P.y - this.C.y) * z0 };
    const M = { x: this.C.x + f.x / z0, y: this.C.y + f.y / z0 };
    const dir = { x: 0.56, y: -0.83 };
    const d0 = zTo > z0 ? 38 : 118, d1 = clamp((d0 * zTo) / z0, 30, 150);
    const [a, b] = this.F as [Finger, Finger];
    const put = (d: number) => {
      a.x = clamp(f.x - dir.x * d, 24, this.fw - 24);
      a.y = clamp(f.y - dir.y * d, 24, this.fh - 24);
      b.x = clamp(f.x + dir.x * d, 24, this.fw - 24);
      b.y = clamp(f.y + dir.y * d, 24, this.fh - 24);
    };
    if (a.o > 0.05) await this.fade(0, 0, 160, tok);
    put(d0);
    const shown = await this.clock.tween(200, (e) => (a.o = b.o = e), tok);
    if (!shown) return false;
    a.down = b.down = true;
    this.follow = false;
    const ok = await this.clock.tween(ms, (e) => {
      this.z = z0 * Math.pow(zTo / z0, e);
      put(lerp(d0, d1, e));
      this.C.x = M.x - f.x / this.z;
      this.C.y = M.y - f.y / this.z;
      this.clampCam();
    }, tok, IO);
    a.down = b.down = false;
    this.follow = true;
    if (!ok) return false;
    return this.clock.tween(220, (e) => (a.o = b.o = 1 - e), tok);
  }

  /** Turn every phone between portrait (0) and landscape (1); the outline's aspect follows. */
  async rotate(to: number, ms: number, tok: Tok) {
    if (this.F[0]!.o > 0.05 && !(await this.fade(0, 0, 180, tok))) return false;
    const o0 = this.ph.o;
    this.follow = false;
    const ok = await this.clock.tween(ms, (e) => {
      const mx = this.C.x + this.vw / 2, my = this.C.y + this.vh / 2;
      const o = lerp(o0, to, e);
      for (const p of this.phones) p.setOrient(o);
      this.z = Math.max(this.z, this.minZ());
      this.C.x = mx - this.vw / 2;
      this.C.y = my - this.vh / 2;
      this.clampCam();
    }, tok, IO);
    this.follow = true;
    return ok;
  }

  keyboard(to: number, ms: number, tok: Tok) {
    const k0 = this.kb;
    return this.clock.tween(ms, (e) => (this.kb = lerp(k0, to, e)), tok, to > k0 ? EASE : IO);
  }

  async type(text: string, tok: Tok, onChar: (typed: string) => void) {
    let typed = "";
    for (const ch of text) {
      typed += ch;
      for (const p of this.phones) p.flashKey(ch);
      onChar(typed);
      if (!(await this.clock.wait(ch === " " ? 85 : 54, tok))) return false;
    }
    return true;
  }

  enter() {
    for (const p of this.phones) p.flashKey("\n");
  }
}
