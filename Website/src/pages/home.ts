import { config } from "../../site.config";
import a2File from "../hero-a2/a2.html" with { type: "text" };
import { html, pd, raw, type Html } from "../lib/html";
import { markSvg } from "../lib/mark";
import { guideCards, icon, ogUrl, page, type Assets } from "./layout";
import { faqPage, graph, softwareApplication, webPage, type QA } from "./schema";

const P = config.pricing;
const R = config.requirements;
const C = config.copy;

/** A price for the Doto numerals, with the decimal point set in the UI face (Doto draws "." like a plus). */
const amount = (price: string) => {
  const [whole, cents] = price.replace("CA$", "").split(".");
  return html`<span class="cur">CA$</span>${whole}${cents ? html`${pd}${cents}` : ""}`;
};

/** The two SVG symbols the demo draws with (the Farside mark and the Mac pointer), from the hero lab. */
const A2_SPRITE = raw(`<svg class="a2-sprite" width="0" height="0" aria-hidden="true" focusable="false">
  <symbol id="mk" viewBox="0 0 26 38"><g fill="#EDE8DF"><circle cx="3" cy="8" r="1.4"/><circle cx="7" cy="8" r="1.4"/><circle cx="3" cy="12" r="1.4"/><circle cx="7" cy="12" r="1.4"/><circle cx="11" cy="12" r="1.4"/><circle cx="3" cy="16" r="1.4"/><circle cx="7" cy="16" r="1.4"/><circle cx="11" cy="16" r="1.4"/><circle cx="15" cy="16" r="1.4"/><circle cx="3" cy="20" r="1.4"/><circle cx="7" cy="20" r="1.4"/><circle cx="11" cy="20" r="1.4"/><circle cx="15" cy="20" r="1.4"/><circle cx="19" cy="20" r="1.4"/><circle cx="3" cy="24" r="1.4"/><circle cx="7" cy="24" r="1.4"/><circle cx="11" cy="24" r="1.4"/><circle cx="15" cy="24" r="1.4"/><circle cx="19" cy="24" r="1.4"/><circle cx="23" cy="24" r="1.4"/><circle cx="3" cy="28" r="1.4"/><circle cx="7" cy="28" r="1.4"/><circle cx="11" cy="28" r="1.4"/><circle cx="3" cy="32" r="1.4"/><circle cx="11" cy="32" r="1.4"/><circle cx="15" cy="32" r="1.4"/><circle cx="15" cy="36" r="1.4"/></g><circle cx="3.2" cy="3.2" r="2.8" fill="#FF5B1F"/></symbol>
  <symbol id="ptr" viewBox="-1.5 -1.5 17 23"><path d="M0 0V16.6L4.1 12.8L6.8 19.1L9.7 17.9L7 11.7H12.7Z" fill="#000" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></symbol>
</svg>`);

/** The approved phone + Mac demo ("A2"), rendered into the page so it holds its size from the first paint. */
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
    <button type="submit">${C.cta}<span class="arr" aria-hidden="true">${icon.arrow}</span></button>
  </form>
  <p class="consent" id="${id}-consent">${C.consent}</p>
  <p class="note" id="${id}-status" role="status" aria-live="polite" tabindex="-1"></p>
</div>`;
}

/** Section heading: mono eyebrow, then a Doto line that reveals with a dot wipe. */
const sh = (id: string, eyebrow: string, title: Html, intro?: Html) => html`<div class="sh" data-rv>
  <div><p class="eyebrow">${eyebrow}</p><h2 class="h2 dw" id="${id}">${title}</h2></div>
  ${intro ? html`<p>${intro}</p>` : ""}
</div>`;

const motionButton = html`<button class="motion" type="button" hidden>
  <svg class="ico i-pause" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M8 5v14M16 5v14"/></svg>
  <svg class="ico i-play" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M7 5l12 7-12 7z"/></svg>
  <span class="lbl">Pause motion</span>
</button>`;

const hero = html`<section class="hero" id="top" aria-labelledby="hero-title">
  <canvas class="hero-cv" aria-hidden="true"></canvas>
  <div class="hero-c w">
    <p class="eyebrow"><i></i>Remote control for your own Mac<i></i></p>
    <h1 class="h1" id="hero-title"><span class="ln dw"><span>Your Mac is far${pd}</span></span> <span class="ln dw"><span>Your reach <em>isn’t.</em></span></span></h1>
    <p class="sub">Farside puts your Mac on your iPhone or iPad and turns the whole screen into a trackpad. One finger points. A tap clicks. Free on your own Wi‑Fi.</p>
    ${joinForm("join-hero")}
  </div>
  <div class="hero-space" aria-hidden="true"></div>
  <p class="corner l" aria-hidden="true">Phone<b>side</b></p>
  <p class="corner r" aria-hidden="true">Mac<b>side</b></p>
  <p class="gapr" aria-hidden="true"><span class="long">Distance to your Mac · </span><b>8,421 km</b></p>
  ${motionButton}
</section>`;

/**
 * Four numbers, each backed by the repo (see Website/README.md, "Stats strip"). No latency or frame-rate
 * figures: the measured ones are for one phone and one Mac, and `bun run check` blocks them on purpose.
 */
const STATS: { n: number; from: number; pre?: string; label: string }[] = [
  { n: 0, from: 12, label: "Accounts to make" },
  { n: 1, from: 9, label: "Code to scan, then you’re paired" },
  { n: 4, from: 0, label: "Pointer sizes, up to Extra Large" },
  { n: 0, from: 99, pre: "CA$", label: "On your own Wi‑Fi" },
];

const stats = html`<section class="stats-sec" aria-label="Farside in four numbers">
  <ul class="stats w" role="list" data-rv>
    ${STATS.map(
      (s) => html`<li class="stat"><b>${s.pre ? html`<small>${s.pre}</small>` : ""}<span data-count="${s.n}" data-from="${s.from}">${s.n}</span></b><span>${s.label}</span></li>`,
    )}
  </ul>
</section>`;

const gap = html`<section class="sec" id="gap" aria-labelledby="gap-title">
  <div class="w">
    ${sh("gap-title", "Try it", html`Close the <em>gap.</em>`, html`Your fingertip on the glass, the pointer on your Mac. Reach for it with your mouse, trackpad or finger. The hand follows with the same soft lag the app’s view uses.`)}
    <div class="gap" data-rv>
      <div class="gap-stage">
        <canvas class="gap-cv" aria-hidden="true"></canvas>
        <p class="gap-hint" aria-hidden="true">Reach for the pointer</p>
      </div>
      <div class="gap-ui">
        <p class="gap-say"><span class="cap gap-cap">Status · reaching</span><span class="gap-line" aria-live="polite">Nearly there. Keep going.</span></p>
        <div class="gap-side">
          <p class="gap-meter"><span class="cap">Gap</span><b class="gap-km">41 cm</b></p>
          <button class="gap-go ghostb" type="button">Close it for me</button>
        </div>
      </div>
    </div>
  </div>
</section>`;

const see = html`<section class="sec" id="see" aria-labelledby="see-title">
  ${A2_SPRITE}
  <div class="w see-grid">
    <div class="see-copy">
      ${sh("see-title", "See it", html`Watch it <em>steer.</em>`)}
      <p class="sec-intro" data-rv="self">Your Mac on top, your iPhone below. Slide on the phone and the pointer moves; the picture follows it. Tap, and it clicks.</p>
      <p class="sec-note" data-rv="self">Drag on the phone screen to try it yourself.</p>
    </div>
    <div class="stage" id="stage">${a2Demo}</div>
  </div>
</section>`;

/** A build-time dither illustration (decorative: the text says it all). */
function art(assets: Assets, key: string): Html {
  const i = assets.img[key];
  if (!i) return html`<span class="art art-ph" aria-hidden="true"></span>`;
  return html`<img class="art" src="${i.src}" width="${i.w}" height="${i.h}" alt="" loading="lazy" decoding="async">`;
}

const how = (assets: Assets) => html`<section class="sec" id="how" aria-labelledby="how-title">
  <div class="w">
    ${sh("how-title", "How it works", html`Three touches${pd}<br> <em>Then</em> you’re in${pd}`, html`No account to make, nothing to set up on your router and no cables.`)}
    <ol class="steps" role="list" data-rv>
      <li class="step">${art(assets, "art-step1")}<p class="n" aria-hidden="true">01</p><h3>Get the free Mac app</h3><p>Install it and turn on the two permissions it asks for. It shows you where.</p></li>
      <li class="step">${art(assets, "art-step2")}<p class="n" aria-hidden="true">02</p><h3>Pair your iPhone</h3><p>Scan the code on your Mac, then approve your phone on the Mac. No account needed.</p></li>
      <li class="step">${art(assets, "art-step3")}<p class="n" aria-hidden="true">03</p><h3>Tap Connect</h3><p>Your Mac’s screen appears, and your phone becomes its trackpad.</p></li>
    </ol>
    <p class="req" data-rv="self">You’ll need ${R.mac}, and an iPhone with ${R.iphone} or an iPad with ${R.ipad}.</p>
  </div>
</section>`;

const features = (assets: Assets) => html`<section class="sec" id="features" aria-labelledby="features-title">
  <div class="w">
    ${sh("features-title", "What it does", html`Small screen${pd}<br> <em>Whole</em> Mac${pd}`, html`Your actual Mac, steered with one thumb. The picture stays sharp; the dots are only decoration.`)}
    <ul class="feats" role="list" data-rv>
      <li class="feat">${art(assets, "art-feat-pad")}<h3>Your screen is the trackpad</h3><p>Slide to move the pointer and tap to click. The pointer is big and sharp, and you feel a small tap with each click.</p></li>
      <li class="feat">${art(assets, "art-feat-zoom")}<h3>Zoom in on small text</h3><p>Pinch to zoom, and the view follows the pointer.</p></li>
      <li class="feat">${art(assets, "art-feat-voice")}<h3>Type or talk</h3><p>Use the keyboard or your voice. Copy and paste works both ways.</p></li>
      <li class="feat">${art(assets, "art-feat-trust")}<h3>Only phones you approve</h3><p>The connection is encrypted, and your Mac asks before any new phone can connect.</p></li>
    </ul>
  </div>
</section>`;

const pricing = html`<section class="sec" id="pricing" aria-labelledby="pricing-title">
  <div class="w">
    ${sh("pricing-title", "Pricing", html`Free at home${pd}<br> A plan for <em>away.</em>`, html`When your iPhone or iPad and your Mac share a Wi‑Fi network, Farside is free. Reaching your Mac from somewhere else is what Anywhere is for.`)}
    <div class="plans" data-rv>
      <article class="plan" aria-labelledby="plan-free">
        <p class="cap">Free at home</p>
        <h3 id="plan-free">On your own Wi‑Fi<span class="sr-only">: free</span></h3>
        <p class="amt">${amount("CA$0")}</p>
        <p class="per">Not a trial in a trench coat.</p>
        <ul role="list">
          <li>Your iPhone or iPad and Mac on the same Wi‑Fi</li>
          <li>Trackpad, keyboard and voice typing</li>
          <li>No account, no ads</li>
        </ul>
        <a class="cta" href="#beta">${C.cta}<span class="arr" aria-hidden="true">${icon.arrow}</span></a>
      </article>
      <article class="plan any" aria-labelledby="plan-any">
        <p class="cap">Anywhere <span class="badge">Planned</span></p>
        <h3 id="plan-any">Past your <em>front door</em></h3>
        <p class="amt">${amount(P.monthly)}<small>a month</small></p>
        <p class="per">or ${P.yearly} a year, about ${P.yearlyPerMonth} a month</p>
        <ul role="list">
          <li>Everything in Free at home</li>
          <li>Use your Mac away from home, on mobile data or any Wi‑Fi</li>
          <li>Starts with a ${P.trialDays}‑day free trial</li>
        </ul>
        <p class="plan-foot">Sold in the iPhone and iPad app, through Apple.</p>
      </article>
    </div>
    <p class="fine" data-rv="self">Prices in Canadian dollars. Anywhere is sold in the app through Apple, which shows your local price before you pay.</p>
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
    ${sh("faq-title", "FAQ", html`Questions<span class="pd">,</span> <em>answered.</em>`)}
    <div class="faq" data-rv>
      ${QAS.map(({ q, a }) => html`<details><summary><span>${q}</span><span class="pm" aria-hidden="true"></span></summary><div class="a">${a}</div></details>`)}
    </div>
    <p class="more" data-rv="self">More answers on the <a href="/support">support page</a>.</p>
    <div class="home-guides" id="guides" data-rv>
      <h3 class="cap">Guides</h3>
      ${guideCards()}
    </div>
  </div>
</section>`;

/**
 * Beta sign-up. Works without JavaScript (a plain form post; the function answers with a redirect to
 * /?joined=1#joined or /?joined=0&error=…#join-error-…). src/scripts/waitlist.ts upgrades it to an in-page request.
 */
const beta = html`<section class="sec join-sec" id="beta" aria-labelledby="beta-title">
  <div class="w">
    <div class="band-mark" aria-hidden="true">${raw(markSvg(44))}</div>
    <p class="eyebrow">Beta</p>
    <h2 class="h2 dw" id="beta-title">${C.cta}</h2>
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
      ogTitle: "Farside · Your Mac is far. Your reach isn’t.",
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
    html`${hero}\n${stats}\n${gap}\n${see}\n${how(assets)}\n${features(assets)}\n${pricing}\n${faq}\n${beta}`,
  );
}
