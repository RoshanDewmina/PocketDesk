import { webFonts } from "./site";
import { startHeroA2 } from "../hero-a2/mount";
import { startPocketHero } from "../hero-pocket/mount";
import { initGap } from "./gap";
import { initWaitlist } from "./waitlist";

initWaitlist();

// The demos are decoration: the hero's starts once the web fonts have swapped in (so a swap can't move it
// once it is painted) and the main thread is idle, so it never competes with the words; the other two start
// when they come near the viewport.
const hero = document.querySelector<HTMLElement>(".hero-demo");
if (hero) {
  const start = () => startPocketHero(hero);
  Promise.race([webFonts, new Promise((r) => setTimeout(r, 2500))]).then(() => {
    if (typeof requestIdleCallback === "function") requestIdleCallback(start, { timeout: 600 });
    else setTimeout(start, 60);
  });
}

function whenNear(el: Element | null, fn: () => void) {
  if (!el) return;
  if (typeof IntersectionObserver !== "function") return fn();
  const io = new IntersectionObserver(
    (es) => {
      if (!es.some((e) => e.isIntersecting)) return;
      io.disconnect();
      fn();
    },
    { rootMargin: "600px 0px" },
  );
  io.observe(el);
}

const gap = document.getElementById("gap");
whenNear(gap, () => initGap(gap!));
whenNear(document.getElementById("stage"), startHeroA2);
