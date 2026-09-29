import "./site";
import { initHero } from "./hero";

// The canvas is decoration: start it once the page has painted and the main thread is idle,
// so it never competes with the words for the first paint.
const hero = document.querySelector<HTMLElement>(".hero");
if (hero) {
  const start = () => initHero(hero);
  if (typeof requestIdleCallback === "function") requestIdleCallback(start, { timeout: 900 });
  else setTimeout(start, 120);
}

// Pricing: monthly / yearly switch for the Anywhere plan.
const tog = document.querySelector<HTMLElement>(".tog");
if (tog) {
  const buttons = [...tog.querySelectorAll<HTMLButtonElement>("button[data-bill]")];
  const panes = [...document.querySelectorAll<HTMLElement>(".price-box [data-bill]")];
  const choose = (bill: string) => {
    buttons.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.bill === bill)));
    panes.forEach((p) => (p.hidden = p.dataset.bill !== bill));
  };
  buttons.forEach((b) => b.addEventListener("click", () => choose(b.dataset.bill!)));
  tog.classList.add("ready");
}
