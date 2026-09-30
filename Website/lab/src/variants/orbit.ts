// Variant 3, "Orbit / split view": a slow 3D camera orbit around the Mac and a small phone, with the phone's
// view shown large beside them and a dotted link from the ember outline to it. Portrait, then landscape, with
// the D34 moment called out: the pointer reaches the edge and the view eases after it.

import type { Tok } from "../clock";
import { h, se } from "../dom";
import { EASE, LIN, REVEAL, clamp, lerp } from "../ease";
import type { Pt } from "../rig";
import type { Instance, Layout, Variant } from "../stage";
import { DONE, park } from "./common";

export function orbitVariant(): Variant {
  const A = { t0: 0, intro: 0, world: 1 };
  let hud: HTMLElement, hudA: HTMLElement, hudB: HTMLElement;
  let lines: SVGLineElement[] = [];
  let marks: HTMLElement[] = [];
  let followO = 0;
  let settledAt = -1;

  const layout = (tall: boolean): Layout =>
    tall
      ? {
          W: 600, H: 1000,
          mac: { cx: 268, top: 84, sw: 390 },
          phone: { p: { cx: 470, cy: 300, k: 0.19 }, l: { cx: 455, cy: 330, k: 0.19 } },
          inset: { p: { cx: 300, cy: 728, k: 0.38 }, l: { cx: 300, cy: 690, k: 0.58 } },
          status: 966,
          hud: { x: 300, y: 470 },
        }
      : {
          W: 1100, H: 640,
          mac: { cx: 322, top: 128, sw: 440 },
          phone: { p: { cx: 560, cy: 410, k: 0.24 }, l: { cx: 535, cy: 450, k: 0.24 } },
          inset: { p: { cx: 890, cy: 330, k: 0.56 }, l: { cx: 862, cy: 330, k: 0.5 } },
          status: 606,
          hud: { x: 868, y: 14 },
        };

  function corners(x: Instance): Pt[] {
    const ph = x.phones[1]!, p = ph.pose, w = (ph.cw * p.k) / 2, hh = (ph.ch * p.k) / 2;
    return [
      { x: p.cx - w, y: p.cy - hh },
      { x: p.cx + w, y: p.cy - hh },
      { x: p.cx + w, y: p.cy + hh },
      { x: p.cx - w, y: p.cy + hh },
    ];
  }

  return {
    layout,
    build(x) {
      x.fig.classList.add("lx-3d");
      x.addPhone({ cls: "lx-small" });
      x.addPhone({ cls: "lx-inset", parent: x.stage, spot: (L) => L.inset });
      marks = [...x.rig.outline.querySelectorAll<HTMLElement>("b")];
      for (let i = 0; i < 4; i++) {
        const l = se("line", { class: "lx-link" });
        x.links.append(l);
        lines.push(l);
      }
      hudA = h("b", "", ["iPhone view"]);
      hudB = h("span", "", ["Smooth follow · pointer 1:1, the view eases after it · settles in ≈0.2 s"]);
      hud = h("div", "lx-hud", [hudA, hudB]);
      x.stage.append(hud);
    },
    reset(x) {
      Object.assign(A, { t0: x.clock.time, intro: 0, world: 1 });
      const r = x.rig;
      r.resetScene();
      r.setTerm(DONE);
      r.focus("fnd");
      for (const p of r.phones) p.setOrient(0);
      park(r, { x: 120, y: 360 }, 2.3);
      r.outlineO = 1;
      r.ptrO = 1;
      followO = 0;
      settledAt = -1;
    },
    frame(x) {
      const t = x.clock.time - A.t0, L = x.L;
      const ry = lerp(-30, 0, A.intro) + 11 * Math.sin((t / 17000) * Math.PI * 2 + 0.4) - 4;
      const rx = 6 + 2.5 * Math.sin((t / 11000) * Math.PI * 2);
      const cy = L.mac.top + L.mac.sw * 0.4;
      x.world.style.transformOrigin = `${L.mac.cx + L.mac.sw * 0.12}px ${cy}px`;
      x.world.style.transform = `scale(${lerp(0.9, 1, A.intro)}) rotateX(${rx}deg) rotateY(${ry}deg)`;
      x.world.style.opacity = String(A.world * clamp(A.intro * 1.5, 0, 1));
      x.phones[0]!.pose.dz = 120;
      const inset = x.phones[1]!;
      inset.pose.opacity = A.world * clamp(A.intro * 1.5 - 0.2, 0, 1);
      x.setStatus(A.world * A.intro);
      hud.style.left = `${L.hud!.x}px`;
      hud.style.top = `${L.hud!.y}px`;
      hud.style.opacity = String(A.world * A.intro);
    },
    post(x) {
      const r = x.rig;
      followO += ((r.following ? 1 : 0) - followO) * 0.2;
      hudA.textContent = `iPhone view · ${r.ph.o < 0.5 ? "portrait" : "landscape"} · ${(r.z / r.minZ()).toFixed(1)}×`;
      hudB.style.opacity = String(Math.max(followO, settledAt >= 0 && x.clock.time - settledAt < 1200 ? 1 : 0));
      if (r.following) settledAt = x.clock.time;
      const to = corners(x);
      const op = String(0.75 * A.world * clamp(A.intro * 1.5 - 0.3, 0, 1) * r.outlineO);
      marks.forEach((m, i) => {
        const a = x.stagePt(m), b = to[i]!, l = lines[i]!;
        l.setAttribute("x1", a.x.toFixed(1));
        l.setAttribute("y1", a.y.toFixed(1));
        l.setAttribute("x2", b.x.toFixed(1));
        l.setAttribute("y2", b.y.toFixed(1));
        l.style.opacity = op;
        l.style.strokeDashoffset = String(-(x.clock.time / 40) % 1000);
      });
    },
    async run(x, tok: Tok) {
      const r = x.rig, c = x.clock, W = (ms: number) => c.wait(ms, tok);
      if (!(await c.tween(1300, (e) => (A.intro = e), tok, EASE))) return false;
      if (!(await W(300))) return false;

      // Select a file in Finder.
      if (!(await r.travel(r.ctr(".f-pho i"), tok))) return false;
      if (!(await r.tap(tok))) return false;
      r.select(".f-pho", true);
      if (!(await W(450))) return false;

      // D34: drag steadily toward the edge and beyond; the pointer stays 1:1, the view eases after it.
      if (!(await r.regrip({ x: 44, y: r.chE * 0.62 }, tok))) return false;
      if (!(await r.glide({ x: r.P.x + 140, y: r.P.y - 20 }, 1900, tok, undefined, LIN))) return false;
      r.fade(0, 0, 260, tok);
      if (!(await W(900))) return false;

      // Pinch in on the chat, then back out.
      if (!(await r.travel(r.ctr(".ch-body .in", 0.4, 0.5), tok))) return false;
      if (!(await r.pinch(3.6, 900, tok))) return false;
      if (!(await W(500))) return false;
      if (!(await r.pinch(2.3, 850, tok))) return false;
      if (!(await W(200))) return false;

      // Landscape: both phones turn, the outline widens, the link follows.
      if (!(await r.rotate(1, 1000, tok))) return false;
      if (!(await W(250))) return false;

      // Reply in Chat.
      if (!(await r.travel(r.ctr(".ch-in", 0.3, 0.5), tok))) return false;
      if (!(await r.tap(tok))) return false;
      r.focus("chat");
      r.flag("typing", true);
      r.fade(0, 0, 220, tok);
      if (!(await r.keyboard(1, 320, tok))) return false;
      if (!(await r.type("on it, 5 min", tok, (s) => r.chatText(s)))) return false;
      if (!(await W(240))) return false;
      r.enter();
      r.chatText("");
      r.flag("sent", true);
      if (!(await W(350))) return false;
      r.flag("typing", false);
      if (!(await r.keyboard(0, 300, tok))) return false;

      // One more edge push, in landscape.
      if (!(await r.regrip({ x: r.cw * 0.12, y: r.chE * 0.55 }, tok))) return false;
      if (!(await r.glide({ x: Math.min(780, r.P.x + 260), y: r.P.y - 50 }, 1700, tok, undefined, LIN))) return false;
      r.fade(0, 0, 300, tok);
      if (!(await W(1500))) return false;
      return c.tween(600, (e) => (A.world = 1 - e), tok, REVEAL);
    },
    still(x) {
      Object.assign(A, { t0: x.clock.time - 2500, intro: 1, world: 1 });
      const r = x.rig;
      r.select(".f-pho", true);
      park(r, r.ctr(".f-pho i"), 2.3);
      followO = 1;
    },
  };
}
