import { webFonts } from "./site";
import { pickLook, startHeroBg } from "../hero-bg/bg";
import { startReach } from "../hero-bg/reach";
import { startPocketHero } from "../hero-pocket/mount";

const idle = (fn: () => void) => (typeof requestIdleCallback === "function" ? requestIdleCallback(fn, { timeout: 600 }) : setTimeout(fn, 60));

// The hero demo and its background are decoration: they start once the web fonts have swapped in (so a swap
// can't move them once painted) and the main thread is idle, so they never compete with the words. The
// background's poster is chosen at once (pickLook) so ?bg= previews show the right one from the start.
const hero = document.querySelector<HTMLElement>(".hero-demo");
const bg = document.querySelector<HTMLElement>(".hero-bg");
const look = bg ? pickLook(bg) : null;
if (hero) {
  const start = () => {
    startPocketHero(hero);
    // Its own idle slot: compiling the shader shouldn't share a task with building the demo.
    if (bg && look) idle(() => (look === "reach" ? startReach(bg) : startHeroBg(bg, look)));
  };
  Promise.race([webFonts, new Promise((r) => setTimeout(r, 2500))]).then(() => {
    idle(start);
  });
}
