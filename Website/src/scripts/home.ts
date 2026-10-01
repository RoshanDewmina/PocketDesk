import { webFonts } from "./site";
import { startPocketHero } from "../hero-pocket/mount";
import { initWaitlist } from "./waitlist";

initWaitlist();

// The hero demo is decoration: it starts once the web fonts have swapped in (so a swap can't move it once it
// is painted) and the main thread is idle, so it never competes with the words.
const hero = document.querySelector<HTMLElement>(".hero-demo");
if (hero) {
  const start = () => startPocketHero(hero);
  Promise.race([webFonts, new Promise((r) => setTimeout(r, 2500))]).then(() => {
    if (typeof requestIdleCallback === "function") requestIdleCallback(start, { timeout: 600 });
    else setTimeout(start, 60);
  });
}
