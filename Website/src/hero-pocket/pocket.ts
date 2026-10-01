// Variant 2, "From the pocket": phone first. The iPhone slides up full-size on Farside's Home screen, Connect
// is tapped, the camera pulls back to reveal the Mac with the outline locking on, a window is dragged across
// the Mac, the phone pinches in and out, then turns to landscape. From the hero lab (website/hero-lab,
// Website/lab/src/variants/pocket.ts); changes: the contact event for the header's status chip, and a shorter gap between loops.

import type { Tok } from "./clock";
import { EASE, LIN, REVEAL, clamp, lerp } from "./ease";
import { PILL } from "./home";
import { lerpRect } from "./rig";
import type { Instance, Layout, Variant } from "./stage";
import { DONE, park } from "./common";

export function pocketVariant(): Variant {
  const A = { cam: 0, rise: 0, home: 0, status: 0, world: 1 };
  /** Only the first run waits before the phone rises; after that the loop goes from fade-out to rise in ~0.3 s. */
  let first = true;
  const INIT = { ...A };

  // src/hero-bg/reach.ts reads these stage sizes and the Mac's position to place the reach art; keep in step.
  const layout = (tall: boolean): Layout =>
    tall
      ? { W: 600, H: 880, mac: { cx: 300, top: 40, sw: 470 }, phone: { p: { cx: 300, cy: 632, k: 0.44 }, l: { cx: 300, cy: 572, k: 0.5 } }, status: 846 }
      : { W: 1000, H: 640, mac: { cx: 400, top: 56, sw: 580 }, phone: { p: { cx: 800, cy: 386, k: 0.42 }, l: { cx: 770, cy: 498, k: 0.42 } }, status: 606 };

  function camera(x: Instance) {
    const L = x.L, ph = x.phones[0]!, p = L.phone.p;
    const S0 = (0.9 * L.H) / (ph.BH * p.k);
    const u = A.cam, sc = lerp(S0, 1, u);
    const px = lerp(L.W / 2, p.cx, u), py = lerp(L.H / 2, p.cy, u);
    x.world.style.transform = u >= 1 ? "" : `translate(${px - p.cx * sc}px,${py - p.cy * sc}px) scale(${sc})`;
    x.macEl.style.opacity = String(clamp(u * 1.4 - 0.15, 0, 1));
  }

  return {
    layout,
    build(x) {
      x.world.style.transformOrigin = "0 0";
      x.addPhone({ home: true });
    },
    reset(x) {
      Object.assign(A, INIT);
      const r = x.rig;
      r.resetScene();
      r.setTerm(DONE);
      r.focus("chat");
      for (const p of r.phones) p.setOrient(0);
      park(r, { x: 150, y: 150 }, 0);
      r.outlineO = 0;
      r.ptrO = 0;
      const home = r.ph.home!;
      home.label.textContent = "Connect";
      home.dot.classList.remove("live");
      home.stat.textContent = "Ready · same Wi-Fi";
    },
    frame(x) {
      camera(x);
      const ph = x.phones[0]!;
      ph.pose.dy = (1 - A.rise) * x.L.H * 0.75;
      ph.pose.rot = (1 - A.rise) * -7;
      ph.pose.opacity = A.rise > 0.001 ? 1 : 0;
      ph.setHome(A.home);
      x.world.style.opacity = String(A.world);
      x.setStatus(A.status * A.world);
    },
    async run(x, tok: Tok) {
      const r = x.rig, c = x.clock, W = (ms: number) => c.wait(ms, tok);
      if (first && !(await W(350))) return false;
      first = false;
      if (!(await c.tween(1050, (e) => (A.rise = e), tok, EASE))) return false;
      if (!(await W(450))) return false;

      const home = r.ph.home!;
      if (!(await r.touch({ x: PILL.x, y: PILL.y + 4 }, { x: 250, y: 820 }, tok))) return false;
      home.label.textContent = "Connecting…";
      document.dispatchEvent(new CustomEvent("farside:contact"));
      home.arrow.animate([{ scale: "1" }, { scale: "1.18" }, { scale: "1" }], { duration: 420, easing: "cubic-bezier(.16,1,.3,1)" });
      r.fade(0, 0, 240, tok);
      if (!(await W(380))) return false;
      home.dot.classList.add("live");
      home.stat.textContent = "Connected";
      r.ptrO = 1;
      if (!(await c.tween(650, (e) => (A.home = e), tok, EASE))) return false;
      if (!(await W(200))) return false;

      // Pull back to reveal the Mac; the outline locks on as it comes into view.
      const view = { x: r.C.x, y: r.C.y, w: r.vw, h: r.vh };
      const big = { x: view.x - view.w * 0.3, y: view.y - view.h * 0.12, w: view.w * 1.6, h: view.h * 1.24 };
      c.tween(1500, (e) => (A.cam = e), tok, EASE);
      if (!(await W(650))) return false;
      c.tween(500, (e) => (A.status = e), tok, REVEAL);
      if (!(await c.tween(800, (e) => {
        r.outlineO = Math.min(1, e * 2);
        r.lock = Math.sin(Math.PI * e);
        r.outlineRect = lerpRect(big, view, e);
      }, tok, EASE))) return false;
      r.outlineRect = null;
      r.lock = 0;
      if (!(await W(300))) return false;

      // Drag the Chat window by its title bar; the view eases after the pointer (D34).
      const bar = r.ctr(".x-chat .s-tb", 0.3, 0.5);
      if (!(await r.travel(bar, tok))) return false;
      if (!(await r.regrip({ x: 70, y: r.chE * 0.42 }, tok))) return false;
      if (!(await W(80))) return false;
      if (!(await r.hold(tok))) return false;
      r.focus("chat");
      const p0 = { ...r.P };
      if (!(await r.glide({ x: p0.x + 165, y: p0.y + 110 }, 1500, tok, () => r.moveWin("chat", r.P.x - p0.x, r.P.y - p0.y)))) return false;
      if (!(await r.release(tok))) return false;
      r.fade(0, 0, 260, tok);
      if (!(await W(350))) return false;

      // Pinch in, look, pinch out.
      if (!(await r.pinch(3.1, 950, tok))) return false;
      if (!(await W(450))) return false;
      if (!(await r.pinch(r.minZ(), 900, tok))) return false;
      if (!(await W(250))) return false;

      // Landscape; skip to the next track.
      if (!(await r.rotate(1, 950, tok))) return false;
      if (!(await W(250))) return false;
      if (!(await r.travel(r.ctr(".mu-ctl .nx"), tok))) return false;
      if (!(await W(90))) return false;
      if (!(await r.tap(tok))) return false;
      r.focus("mus");
      r.flag("nx", true);
      r.fade(0, 0, 400, tok);
      if (!(await W(1800))) return false;
      return c.tween(300, (e) => (A.world = 1 - e), tok, LIN);
    },
    still(x) {
      Object.assign(A, { cam: 1, rise: 1, home: 1, status: 1, world: 1 });
      const r = x.rig;
      r.moveWin("chat", 165, 110);
      r.focus("chat");
      park(r, { x: 340, y: 190 }, 0);
      r.outlineO = 1;
      r.ptrO = 1;
      const home = r.ph.home!;
      home.dot.classList.add("live");
    },
  };
}
