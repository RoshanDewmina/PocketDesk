import "./site";
import { startHeroA2 } from "../hero-a2/mount";
import { initGap } from "./gap";
import { initHero } from "./hero";
import { initWaitlist } from "./waitlist";

initWaitlist();

// The canvases are decoration: the hero starts once the page has painted and the main thread is idle,
// so it never competes with the words; the other two start when they come near the viewport.
const hero = document.querySelector<HTMLElement>(".hero");
if (hero) {
  const start = () => initHero(hero);
  if (typeof requestIdleCallback === "function") requestIdleCallback(start, { timeout: 900 });
  else setTimeout(start, 120);
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
