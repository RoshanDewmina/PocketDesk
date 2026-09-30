// Starts the hero demo. The markup is already in the page (rendered from a2.html at build time), so the hero
// keeps its size from the first paint; the scene stays hidden until the demo has scaled it (.devs.ready).

import { initA2 } from "./a2.js";
import { mount } from "./env";

export function startHeroA2() {
  const el = document.getElementById("stage");
  const devs = el?.querySelector<HTMLElement>(".devs.a2");
  if (!el || !devs) return;
  mount(el);
  initA2();
  devs.classList.add("ready");
}
