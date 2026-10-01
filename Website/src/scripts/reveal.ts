// Scroll reveals, stat count-ups and the header's live chip, shared by every page.
//
// Only things that start below the fold are hidden (the script runs after the first paint, so hiding what
// is already on screen would blink). Each [data-rv] block fades up when it scrolls in; its children follow
// 70 ms apart, and a Doto heading inside (.dw) reveals with a dot wipe. Reduce Motion, Save-Data and the
// pause switch skip all of it: everything is simply there.

import { easeOutExpo } from "./art/shapes";
import { motionAllowed } from "./motion";

const STAGGER_MS = 70;

function countUp(el: HTMLElement) {
  const to = Number(el.dataset.count);
  const from = Number(el.dataset.from);
  const start = performance.now();
  const tick = (n: number) => {
    const k = Math.min(1, (n - start) / 1300);
    el.textContent = String(Math.round(from + (to - from) * easeOutExpo(k)));
    if (k < 1) requestAnimationFrame(tick);
  };
  el.textContent = String(from);
  requestAnimationFrame(tick);
}

export function initReveals() {
  if (!motionAllowed() || typeof IntersectionObserver !== "function") return;
  const blocks = [...document.querySelectorAll<HTMLElement>("[data-rv]")];
  const below = blocks.filter((el) => el.getBoundingClientRect().top > window.innerHeight * 0.92);
  if (!below.length) return;
  for (const el of below) {
    el.querySelectorAll<HTMLElement>("[data-count]").forEach((n) => (n.textContent = n.dataset.from ?? n.textContent));
    if (el.dataset.rv === "self") {
      el.classList.add("rv-self");
      continue;
    }
    el.classList.add("rv");
    [...el.children].forEach((c, i) => (c as HTMLElement).style.setProperty("--i", String(Math.min(i, 8))));
  }
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        const el = e.target as HTMLElement;
        io.unobserve(el);
        el.classList.add("in");
        el.querySelectorAll<HTMLElement>("[data-count]").forEach((n, i) => setTimeout(() => countUp(n), 150 + i * STAGGER_MS));
      }
    },
    { rootMargin: "0px 0px -12% 0px", threshold: 0.05 },
  );
  below.forEach((el) => io.observe(el));
}

/**
 * The header chip ("Your Mac · Awake"): its dot lights ember at a contact moment. On the home page that is
 * the hero's touch; elsewhere the page itself "connects" a beat after it loads.
 */
export function initStatusChip() {
  const chip = document.querySelector<HTMLElement>(".status");
  if (!chip) return;
  const label = chip.querySelector<HTMLElement>(".st-t");
  const on = () => {
    chip.classList.add("hit");
    if (label) label.textContent = "Awake · in reach";
  };
  if (document.querySelector(".hero-demo") && motionAllowed()) {
    document.addEventListener("farside:contact", on, { once: true });
    // Fallback only: the demo waits for the web fonts and an idle moment, then taps Connect about 2.7 s in.
    setTimeout(on, 7000);
  } else if (motionAllowed()) setTimeout(on, 700);
  else on();
}
