// Variant 1, "Lid open": the MacBook opens and boots in halftone, the phone rises in portrait on Farside's
// Home screen, Connect sends an ember pulse across the gap, the outline locks on, the phone pans, pinches in on
// zsh and types, pinches out, turns to landscape and presses play on Slow Orbit.

import type { Tok } from "../clock";
import { EASE, LIN, REVEAL, clamp, lerp } from "../ease";
import { ARROW } from "../home";
import { DH, DW, lerpRect } from "../rig";
import type { Instance, Layout, Variant } from "../stage";
import { CMD, OUT, park, prompt, promptEnd } from "./common";

export function lidVariant(): Variant {
  const A = { lid: -90, pov: -140, boot: 0, scene: 0, rise: 0, home: 0, status: 0, world: 1 };
  const INIT = { ...A };
  let bits: HTMLElement[] = [];
  let wall: HTMLElement | null = null;
  let bootKey = "";

  function drawBoot(x: Instance) {
    const cv = x.boot, b = A.boot;
    cv.style.opacity = String(b <= 0 ? 0 : 1 - A.scene);
    const key = `${b.toFixed(4)}|${cv.width}`;
    if (key === bootKey) return;
    bootKey = key;
    const c = cv.getContext("2d")!;
    const w = x.L.mac.sw, hh = w * 0.625, d = cv.width / w;
    c.setTransform(d, 0, 0, d, 0, 0);
    c.clearRect(0, 0, w, hh);
    if (b <= 0) return;
    const ox = w * 0.42, oy = hh * 1.18, max = Math.hypot(w * 0.58, oy), R = b * max * 1.2, band = max * 0.17, sp = (w / DW) * 9;
    const rows: [number, number, number][] = [];
    for (let y = sp / 2; y < hh; y += sp) {
      for (let xx = sp / 2; xx < w; xx += sp) {
        const dd = Math.hypot(xx - ox, y - oy), q = 1 - Math.abs(dd - R) / band;
        let a = dd < R ? 0.16 : 0;
        if (q > 0) a = Math.max(a, q * q * 0.95);
        if (a > 0.02) rows.push([xx, y, a]);
      }
    }
    for (const [xx, y, a] of rows) {
      c.fillStyle = `rgba(237,232,223,${a.toFixed(3)})`;
      c.beginPath();
      c.arc(xx, y, sp * (0.14 + 0.16 * a), 0, Math.PI * 2);
      c.fill();
    }
  }

  const layout = (tall: boolean): Layout =>
    tall
      ? { W: 600, H: 880, mac: { cx: 300, top: 40, sw: 470 }, phone: { p: { cx: 300, cy: 632, k: 0.44 }, l: { cx: 300, cy: 572, k: 0.5 } }, status: 846 }
      : { W: 1000, H: 640, mac: { cx: 420, top: 44, sw: 590 }, phone: { p: { cx: 832, cy: 392, k: 0.43 }, l: { cx: 790, cy: 500, k: 0.43 } }, status: 606 };

  return {
    layout,
    build(x) {
      x.addPhone({ home: true });
      bits = [...x.rig.macScene.querySelectorAll<HTMLElement>(".s-menu,.s-win:not(.x-dlg),.s-dock")];
      wall = x.rig.macScene.querySelector<HTMLElement>(".s-wall");
    },
    reset(x) {
      Object.assign(A, INIT);
      bootKey = "";
      const r = x.rig;
      r.resetScene();
      r.flag("paused", true);
      r.setTerm([prompt("")]);
      r.focus("chat");
      for (const p of r.phones) p.setOrient(0);
      park(r, { x: 175, y: 250 }, 0);
      r.outlineO = 0;
      r.ptrO = 0;
      const home = r.ph.home!;
      home.label.textContent = "Connect";
      home.dot.classList.remove("live");
      home.stat.textContent = "Ready · same Wi-Fi";
    },
    frame(x) {
      x.lid.style.transform = `translateY(-1px) rotateX(${A.lid}deg)`;
      x.macEl.style.perspectiveOrigin = `50% ${A.pov}%`;
      drawBoot(x);
      bits.forEach((el, i) => {
        const e = clamp(A.scene * 1.9 - i * 0.12, 0, 1);
        el.style.opacity = String(e);
        el.style.scale = String(0.95 + 0.05 * e);
      });
      if (wall) wall.style.opacity = String(A.scene);
      const ph = x.phones[0]!;
      ph.pose.dy = (1 - A.rise) * x.L.H * 0.85;
      ph.pose.rot = (1 - A.rise) * 9;
      ph.pose.opacity = A.rise > 0.001 ? 1 : 0;
      ph.setHome(A.home);
      x.world.style.opacity = String(A.world);
      x.setStatus(A.status * A.world);
    },
    async run(x, tok: Tok) {
      const r = x.rig, c = x.clock, W = (ms: number) => c.wait(ms, tok);
      if (!(await W(450))) return false;
      c.tween(1700, (e) => (A.pov = lerp(-140, 36, e)), tok, EASE);
      if (!(await c.tween(1500, (e) => (A.lid = lerp(-90, 0, e)), tok, EASE))) return false;
      if (!(await c.tween(1000, (e) => (A.boot = e), tok, LIN))) return false;
      c.tween(750, (e) => (A.scene = e), tok, REVEAL);
      if (!(await W(200))) return false;
      if (!(await c.tween(950, (e) => (A.rise = e), tok, EASE))) return false;
      if (!(await W(250))) return false;

      // Tap Connect: ember contact on the glass, a pulse crosses the gap and lands on the Mac.
      const ph = r.ph, home = ph.home!;
      if (!(await r.touch({ x: ARROW.x - 6, y: ARROW.y + 4 }, { x: 260, y: 800 }, tok))) return false;
      home.label.textContent = "Connecting…";
      r.fade(0, 0, 220, tok);
      const land = { x: r.C.x + r.vw / 2, y: r.C.y + r.vh / 2 };
      x.field.pulse(x.stagePt(home.arrow), x.macPt(land.x, land.y), 820);
      if (!(await W(820))) return false;
      r.ring(r.macScr, land.x * r.ms, land.y * r.ms, 2.4, "m");
      const lp = x.macPt(land.x, land.y);
      x.field.ripple(lp.x, lp.y);
      home.dot.classList.add("live");
      home.stat.textContent = "Connected";
      c.tween(450, (e) => (A.status = e), tok, REVEAL);

      // The phone opens the live picture; the outline locks onto the region it shows.
      c.tween(700, (e) => (A.home = e), tok, EASE);
      r.ptrO = 1;
      const view = { x: r.C.x, y: r.C.y, w: r.vw, h: r.vh };
      if (!(await c.tween(850, (e) => {
        r.outlineO = Math.min(1, e * 1.6);
        r.lock = Math.sin(Math.PI * e);
        r.outlineRect = lerpRect({ x: 0, y: 0, w: DW, h: DH }, view, e);
      }, tok, EASE))) return false;
      r.outlineRect = null;
      r.lock = 0;
      if (!(await W(250))) return false;

      // Pan to the terminal (the view eases after the pointer near the edge), pinch in on zsh.
      if (!(await r.travel({ x: 520, y: 236 }, tok))) return false;
      if (!(await W(150))) return false;
      if (!(await r.pinch(2.7, 950, tok))) return false;
      if (!(await r.travel(promptEnd(r, ""), tok))) return false;
      if (!(await r.tap(tok))) return false;
      r.focus("term");
      r.fade(0, 0, 240, tok);
      if (!(await r.keyboard(1, 340, tok))) return false;
      if (!(await W(120))) return false;
      if (!(await r.type(CMD, tok, (s) => r.setTerm([prompt(s)])))) return false;
      if (!(await W(220))) return false;
      r.enter();
      for (let i = 1; i <= OUT.length; i++) {
        r.setTerm([prompt(CMD), ...OUT.slice(0, i)], false);
        if (!(await W(i === 1 ? 380 : 440))) return false;
      }
      r.setTerm([prompt(CMD), ...OUT, prompt("")]);
      if (!(await r.keyboard(0, 320, tok))) return false;
      if (!(await r.pinch(r.minZ(), 900, tok))) return false;
      if (!(await W(200))) return false;

      // Landscape, then play Slow Orbit.
      if (!(await r.rotate(1, 950, tok))) return false;
      if (!(await W(250))) return false;
      if (!(await r.travel(r.ctr(".mu-ctl .pl"), tok))) return false;
      if (!(await W(90))) return false;
      if (!(await r.tap(tok))) return false;
      r.focus("mus");
      r.flag("paused", false);
      r.fade(0, 0, 400, tok);
      if (!(await W(1900))) return false;
      return c.tween(550, (e) => (A.world = 1 - e), tok, LIN);
    },
    still(x) {
      Object.assign(A, { lid: 0, pov: 36, boot: 1, scene: 1, rise: 1, home: 1, status: 1, world: 1 });
      const r = x.rig;
      r.setTerm([prompt(CMD), ...OUT, prompt("")]);
      r.flag("paused", false);
      r.focus("mus");
      for (const p of r.phones) p.setOrient(1);
      park(r, r.ctr(".mu-ctl .pl"), 1.75);
      r.outlineO = 1;
      r.ptrO = 1;
    },
  };
}
