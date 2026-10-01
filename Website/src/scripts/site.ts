// Shared behaviour for every page. Kept small: fonts, the mobile menu, the motion switch, scroll reveals and
// the footer.

import { FONTS_URL } from "../lib/fonts";
import { isPaused, onMotionChange, prefersReduced, setPaused } from "./motion";
import { initFooter } from "./footer";
import { initReveals, initStatusChip } from "./reveal";

initReveals();
initStatusChip();

// Web fonts load right after the first paint, so they never hold up the words. The local fallback
// faces (src/styles/fallbacks.css) share their metrics, so the swap should move nothing; where a fallback
// face is missing it can, so `webFonts` resolves once the swap is done (or failed) for anything that waits.
export const webFonts = new Promise<void>((done) => {
  requestAnimationFrame(() =>
    setTimeout(() => {
      const sheet = document.createElement("link");
      sheet.rel = "stylesheet";
      sheet.href = FONTS_URL;
      sheet.onload = () => requestAnimationFrame(() => (document.fonts ? document.fonts.ready.then(() => done()) : done()));
      sheet.onerror = () => done();
      document.head.appendChild(sheet);
    }, 0),
  );
});

// The footer's dot field starts only when the end of the page comes near (src/scripts/footer.ts).
initFooter(webFonts);

// Mobile menu: a <details> disclosure that also closes on Escape, outside clicks and link taps.
const menu = document.querySelector<HTMLDetailsElement>(".nav-mob");
if (menu) {
  const summary = menu.querySelector("summary");
  const close = (focus: boolean) => {
    if (!menu.open) return;
    menu.open = false;
    if (focus) summary?.focus();
  };
  menu.addEventListener("click", (e) => {
    if ((e.target as Element).closest("a")) close(false);
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") close(true);
  });
  document.addEventListener("click", (e) => {
    if (!menu.contains(e.target as Node)) close(false);
  });
  const sync = () => summary?.setAttribute("aria-label", menu.open ? "Close menu" : "Menu");
  menu.addEventListener("toggle", sync);
  sync();
}

// "Join the beta" links lead to the sign-up form on the home page; remember which page the tap came from
// so the form can send it as its source (a page name such as "support" or "guide").
document.addEventListener("click", (e) => {
  const link = (e.target as Element | null)?.closest?.('a[href="/#beta"], a[href="#beta"]');
  if (!link) return;
  try {
    sessionStorage.setItem("farside:src", document.body.dataset.src ?? "site");
  } catch {
    /* storage blocked: the form falls back to "home" */
  }
});

// Long documents: the table of contents is a disclosure on phones and stays open beside the text on wide screens.
const wide = window.matchMedia("(min-width: 900px)");
const tocs = [...document.querySelectorAll<HTMLDetailsElement>("details[data-wide-open]")];
const syncToc = () => tocs.forEach((d) => (d.open = wide.matches));
wide.addEventListener("change", syncToc);
syncToc();

// Motion switch (home hero). Hidden when the OS already asks for less motion.
const motionBtn = document.querySelector<HTMLButtonElement>(".motion");
if (motionBtn) {
  const label = motionBtn.querySelector<HTMLElement>(".lbl");
  const render = () => {
    motionBtn.hidden = prefersReduced();
    motionBtn.dataset.paused = isPaused() ? "true" : "false";
    if (label) label.textContent = isPaused() ? "Play motion" : "Pause motion";
  };
  motionBtn.addEventListener("click", () => setPaused(!isPaused()));
  onMotionChange(render);
  render();
}
