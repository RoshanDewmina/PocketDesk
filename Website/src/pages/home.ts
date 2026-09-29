import { config } from "../../site.config";
import a2File from "../hero-a2/a2.html" with { type: "text" };
import { html, pd, raw, type Html } from "../lib/html";
import { markSvg } from "../lib/mark";
import { photo } from "./images";
import { icon, ogUrl, page, type Assets } from "./layout";
import { faqPage, graph, softwareApplication, webPage, type QA } from "./schema";

const P = config.pricing;
const R = config.requirements;
const C = config.copy;

/** A price for the Doto numerals, with the decimal point set in the UI face (Doto draws "." like a plus). */
const amount = (price: string) => {
  const [whole, cents] = price.split(".");
  return cents ? html`${whole}${pd}${cents}` : html`${price}`;
};


/** A real app screenshot in a simple device frame. */
function shotImg(assets: Assets, key: string, sizes: string, eager = false): Html {
  const i = assets.img[key];
  if (!i) return html``;
  const load = eager ? raw(' fetchpriority="high"') : raw(' loading="lazy"');
  return html`<img src="${i.src}" srcset="${i.srcset ?? i.src}" sizes="${sizes}" width="${i.w}" height="${i.h}" alt="${photo(key).alt}"${load} decoding="async">`;
}

/** The two SVG symbols the hero demo draws with (the Farside mark and the Mac pointer), from the hero lab. */
const A2_SPRITE = raw(`<svg class="a2-sprite" width="0" height="0" aria-hidden="true" focusable="false">
  <symbol id="mk" viewBox="0 0 26 38"><g fill="#EDE8DF"><circle cx="3" cy="8" r="1.4"/><circle cx="7" cy="8" r="1.4"/><circle cx="3" cy="12" r="1.4"/><circle cx="7" cy="12" r="1.4"/><circle cx="11" cy="12" r="1.4"/><circle cx="3" cy="16" r="1.4"/><circle cx="7" cy="16" r="1.4"/><circle cx="11" cy="16" r="1.4"/><circle cx="15" cy="16" r="1.4"/><circle cx="3" cy="20" r="1.4"/><circle cx="7" cy="20" r="1.4"/><circle cx="11" cy="20" r="1.4"/><circle cx="15" cy="20" r="1.4"/><circle cx="19" cy="20" r="1.4"/><circle cx="3" cy="24" r="1.4"/><circle cx="7" cy="24" r="1.4"/><circle cx="11" cy="24" r="1.4"/><circle cx="15" cy="24" r="1.4"/><circle cx="19" cy="24" r="1.4"/><circle cx="23" cy="24" r="1.4"/><circle cx="3" cy="28" r="1.4"/><circle cx="7" cy="28" r="1.4"/><circle cx="11" cy="28" r="1.4"/><circle cx="3" cy="32" r="1.4"/><circle cx="11" cy="32" r="1.4"/><circle cx="15" cy="32" r="1.4"/><circle cx="15" cy="36" r="1.4"/></g><circle cx="3.2" cy="3.2" r="2.8" fill="#FF5B1F"/></symbol>
  <symbol id="ptr" viewBox="-1.5 -1.5 17 23"><path d="M0 0V16.6L4.1 12.8L6.8 19.1L9.7 17.9L7 11.7H12.7Z" fill="#000" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></symbol>
</svg>`);

/** The approved hero demo ("A2"), rendered into the page so it holds its size from the first paint. */
const a2Markup = a2File as unknown as string;
const a2Demo = raw(a2Markup.replace(/^\s*<template[^>]*>/, "").replace(/<\/template>\s*$/, ""));

/**
 * Beta sign-up, used in the hero and in #beta. A plain form post works without JavaScript (the waitlist
 * function redirects to /?joined=1#joined or /?joined=0&error=<code>#join-error-<code>, shown in #beta);
 * src/scripts/waitlist.ts turns it into an in-page request. The consent line sits right under the button.
 */
function joinForm(id: string): Html {
  return html`<div class="wl" id="${id}">
  <form class="join" method="post" action="${config.waitlist.action}" data-waitlist data-status="${id}-status">
    <input type="hidden" name="source" value="home">
    <div class="hp" hidden><label for="${id}-company">Leave this empty</label><input id="${id}-company" name="company" type="text" tabindex="-1" autocomplete="off"></div>
    <label class="sr-only" for="${id}-email">Email address</label>
    <input id="${id}-email" name="email" type="email" inputmode="email" autocomplete="email" autocapitalize="off" spellcheck="false" required maxlength="254" placeholder="Email address" aria-describedby="${id}-consent ${id}-status">
    <button type="submit">${C.cta}</button>
  </form>
  <p class="consent" id="${id}-consent">${C.consent}</p>
  <p class="note" id="${id}-status" role="status" aria-live="polite" tabindex="-1"></p>
</div>`;
}

const hero = html`<section class="hero" data-v="a2" aria-labelledby="hero-title">
  ${A2_SPRITE}
  <div class="w hero-grid">
    <div class="copy">
      <h1 id="hero-title">Control your Mac from your iPhone.</h1>
      <p class="sub">Your phone is the screen and the trackpad. Free on your Wi‑Fi.</p>
      ${joinForm("join-hero")}
    </div>
    <div class="stage" id="stage">${a2Demo}</div>
  </div>
</section>`;

const how = (assets: Assets) => html`<section class="sec" id="how" aria-labelledby="how-title">
  <div class="w how-grid">
    <div>
      <h2 class="h2" id="how-title">How it works</h2>
      <ol class="steps" role="list">
        <li><h3>Get the free Mac app</h3><p>Install it and turn on the two permissions it asks for. It shows you where.</p></li>
        <li><h3>Pair your iPhone</h3><p>Scan the code on your Mac, then approve your phone on the Mac. No account needed.</p></li>
        <li><h3>Tap Connect</h3><p>Your Mac’s screen appears, and your phone becomes its trackpad.</p></li>
      </ol>
      <p class="req">You’ll need ${R.mac}, and an iPhone with ${R.iphone} or an iPad with ${R.ipad}.</p>
    </div>
    <div class="shot-wrap">
      <div class="shotframe">${shotImg(assets, "photo-home", "(min-width: 1000px) 300px, 260px")}</div>
    </div>
  </div>
</section>`;

const features = html`<section class="sec" id="features" aria-labelledby="features-title">
  <div class="w">
    <h2 class="h2" id="features-title">Made for a small screen</h2>
    <ul class="feats" role="list">
      <li><h3>Your screen is the trackpad</h3><p>Slide to move the pointer and tap to click. The pointer is big and sharp, and you feel a small tap with each click.</p></li>
      <li><h3>Zoom in on small text</h3><p>Pinch to zoom, and the view follows the pointer.</p></li>
      <li><h3>Type or talk</h3><p>Use the keyboard or your voice. Copy and paste works both ways.</p></li>
      <li><h3>Only phones you approve</h3><p>The connection is encrypted, and your Mac asks before any new phone can connect.</p></li>
    </ul>
  </div>
</section>`;

const pricing = html`<section class="sec" id="pricing" aria-labelledby="pricing-title">
  <div class="w">
    <h2 class="h2" id="pricing-title">Pricing</h2>
    <div class="plans">
      <article class="plan" aria-labelledby="plan-free">
        <h3 id="plan-free">Free</h3>
        <p class="amt">CA$0</p>
        <p class="what">When your iPhone or iPad and your Mac are on the same Wi‑Fi. No account, no ads.</p>
      </article>
      <article class="plan" aria-labelledby="plan-any">
        <h3 id="plan-any">Anywhere <span class="badge">Planned</span></h3>
        <p class="amt">${amount(P.monthly)}<small>a month</small></p>
        <p class="alt">or ${P.yearly} a year</p>
        <p class="what">Use your Mac away from home, on mobile data or any Wi‑Fi. Starts with a ${P.trialDays}‑day free trial.</p>
      </article>
    </div>
    <p class="fine">Prices in Canadian dollars. Anywhere is sold in the app through Apple, which shows your local price before you pay.</p>
  </div>
</section>`;

const QAS: QA[] = [
  {
    q: "Is it really free?",
    a: html`<p>Yes, when your iPhone or iPad and your Mac are on the same Wi‑Fi network. There’s no account and no ads. To use your Mac away from home you’ll need the Anywhere plan: ${P.monthly} a month or ${P.yearly} a year (planned), after a ${P.trialDays}-day free trial.</p>`,
  },
  {
    q: "What do I need?",
    a: html`<p>${R.mac}, with the free Farside Mac app, and an iPhone with ${R.iphone} or an iPad with ${R.ipad}. These are the planned requirements. The <a href="/control-mac-from-iphone">setup guide</a> walks you through it.</p>`,
  },
  {
    q: "Can anyone else see my screen?",
    a: html`<p>No. Your screen, typing and voice travel between your own devices, encrypted. You approve every phone on your Mac, and you can stop sharing from the Mac’s menu bar at any time. The <a href="/privacy">privacy policy</a> has the details.</p>`,
  },
  {
    q: "Does my Mac need to be awake?",
    a: html`<p>Yes. Farside can’t wake a sleeping Mac or log in for you. While your phone is connected, it keeps the Mac awake.</p>`,
  },
  { q: "Will I hear my Mac’s sound?", a: html`<p>No. Sound keeps playing on the Mac itself.</p>` },
  { q: "Does it work with Windows or Android?", a: html`<p>No. Farside is for Macs, used from an iPhone or iPad.</p>` },
  {
    q: "Can it tell me when an AI agent on my Mac needs me?",
    a: html`<p>Yes, as a beta feature. If a coding agent on your Mac stops to ask for something, Farside can alert your iPhone. It’s off until you turn it on, and the alert doesn’t include what’s on your screen.</p>`,
  },
  {
    q: "When can I get it?",
    a: html`<p>Farside is in beta testing. <a href="#beta">Join the beta</a> and we’ll email you an invite.</p>`,
  },
];

const faq = html`<section class="sec" id="faq" aria-labelledby="faq-title">
  <div class="w faq-w">
    <h2 class="h2" id="faq-title">Questions</h2>
    <div class="faq">
      ${QAS.map(({ q, a }) => html`<details><summary><span>${q}</span><span class="pm" aria-hidden="true"></span></summary><div class="a">${a}</div></details>`)}
    </div>
    <p class="more">More answers on the <a href="/support">support page</a>.</p>
  </div>
</section>`;

/**
 * Beta sign-up. Works without JavaScript (a plain form post; the function answers with a redirect to
 * /?joined=1#beta or /?joined=0&error=…#beta). src/scripts/home.ts upgrades it to an in-page request and
 * turns those query strings into a message.
 */
const beta = html`<section class="sec join-sec" id="beta" aria-labelledby="beta-title">
  <div class="w">
    <div class="band-mark" aria-hidden="true">${raw(markSvg(44))}</div>
    <h2 class="h2" id="beta-title">${C.cta}</h2>
    <p class="sec-intro">Try Farside before it launches. ${C.availability}</p>
    <div class="join-notes">
      <p id="joined">You’re on the list. We’ll email you when your beta invite is ready.</p>
      <p id="join-error-invalid_email">That email address doesn’t look right. Check it and try again.</p>
      <p id="join-error-rate_limited">Too many tries from your connection. Please try again in a few minutes.</p>
      <p id="join-error-forbidden">That sign-up was blocked. Reload this page and try again.</p>
    </div>
    ${joinForm("join-beta")}
  </div>
</section>`;

const DESC =
  "Control your Mac from your iPhone or iPad. See your Mac’s screen and use it with your finger. Free on the same Wi‑Fi, with no account.";

export function homePage(assets: Assets) {
  const image = ogUrl(assets, "home");
  return page(
    {
      path: "/",
      title: "Farside: Control your Mac from your iPhone",
      ogTitle: "Farside · Control your Mac from your iPhone",
      description: DESC,
      script: "home",
      bodyClass: "home",
      og: "home",
      jsonLd: graph(
        webPage({ path: "/", name: "Farside: Control your Mac from your iPhone", description: DESC, image }),
        softwareApplication(image),
        faqPage("/", QAS),
      ),
    },
    assets,
    html`${hero}\n${how(assets)}\n${features}\n${pricing}\n${faq}\n${beta}`,
  );
}
