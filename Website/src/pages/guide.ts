// Building blocks for the long-form guide and comparison pages.

import { config } from "../../site.config";
import { html, raw, type Html } from "../lib/html";
import { markSvg } from "../lib/mark";
import { longDate, updated } from "./dates";
import { shot } from "./images";
import { breadcrumbNav, icon, type Assets } from "./layout";
import type { QA } from "./schema";

/** A design-preview image from concept 21, lazy-loaded, with 1x/2x sources. */
export function figure(assets: Assets, key: string, caption: string, opts: { eager?: boolean } = {}): Html {
  const i = assets.img[key];
  if (!i) return html``;
  const s = shot(key);
  const load = opts.eager ? raw(' fetchpriority="high"') : raw(' loading="lazy"');
  return html`<figure class="shot${i.w > 500 ? " wide" : ""}"><img src="${i.src}" srcset="${i.src} 1x, ${i.src2x} 2x" width="${i.w}" height="${i.h}" alt="${s.alt}"${load} decoding="async"><figcaption><span class="cap">Design preview</span> ${caption}</figcaption></figure>`;
}

export function guideHero(opts: { crumbs: [string, string][]; cap: string; title: Html; lead: Html; meta?: string }): Html {
  return html`<section class="page-hero guide-hero" aria-labelledby="page-title">
  <div class="band-dots htone" aria-hidden="true"></div>
  <div class="w">
    ${breadcrumbNav(opts.crumbs)}
    <p class="cap">${opts.cap}</p>
    <h1 class="h-page dw" id="page-title">${opts.title}</h1>
    <p class="lead">${opts.lead}</p>
    <p class="meta-row"><span class="cap">Updated · <b>${longDate(updated(opts.crumbs[opts.crumbs.length - 1]![1]))}</b></span>${opts.meta ? html`<span class="cap">${opts.meta}</span>` : ""}<span class="cap">Status · <b>in beta, coming soon</b></span></p>
  </div>
</section>`;
}

/** Numbered steps; each has an anchor (#step-n) that the HowTo JSON-LD points at. */
export function steps(list: { title: string; body: Html; figure?: Html }[]): Html {
  return html`<ol class="steps-doc" role="list">${list.map(
    (s, i) =>
      html`<li id="step-${i + 1}"><div class="st-n" aria-hidden="true">${String(i + 1).padStart(2, "0")}</div><div class="st-b"><h3>${s.title}</h3>${s.body}${s.figure ?? ""}</div></li>`,
  )}</ol>`;
}

export function faqList(qas: QA[]): Html {
  return html`<div class="faq">${qas.map(
    ({ q, a }) => html`<details><summary><span>${q}</span><span class="pm" aria-hidden="true"></span></summary><div class="a">${a}</div></details>`,
  )}</div>`;
}

/** Closing call to action shared by the guides: the beta sign-up on the home page. */
export function ctaBand(): Html {
  return html`<section class="sec band band-sm" aria-labelledby="cta-title">
  <div class="w">
    <div class="band-mark" aria-hidden="true">${raw(markSvg(40))}</div>
    <h2 class="h2" id="cta-title">Try Farside first</h2>
    <p class="lead">Farside is in beta. It’s free when your iPhone and Mac are on the same Wi‑Fi, and there’s no account.</p>
    <div class="row"><a class="cta" href="/#beta">${config.copy.cta}<span class="arr">${icon.arrow}</span></a></div>
  </div>
</section>`;
}

/**
 * The gesture list on the support page: only what has been confirmed on a device (1 Oct 2026). Add the
 * others (double-tap, two-finger tap and drag, double-tap-hold drag) back as each passes its bulk-test line.
 */
export const GESTURES: [string, string][] = [
  ["Slide one finger", "Move the pointer (it moves, it doesn’t jump to your finger)"],
  ["Tap", "Click where the pointer is"],
  ["Pinch", "Zoom the view in or out"],
  ["Swipe up on the handle", "Show the controls, including the keyboard"],
];

export function gestureTable(): Html {
  return html`<table class="table gest-t">
  <caption class="sr-only">Farside gestures and what they do on the Mac</caption>
  <thead><tr><th scope="col">On your iPhone</th><th scope="col">On your Mac</th></tr></thead>
  <tbody>${GESTURES.map(([g, a]) => html`<tr><th scope="row">${g}</th><td>${a}</td></tr>`)}</tbody>
</table>`;
}
