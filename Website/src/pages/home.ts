import { config } from "../../site.config";
import a2File from "../hero-a2/a2.html" with { type: "text" };
import { html, pd, raw, type Html } from "../lib/html";
import { cta, ctaButton, ctaSentence, ogUrl, page, type Assets } from "./layout";
import { faqPage, graph, softwareApplication, webPage, type QA } from "./schema";

// The home page, kept short (owner, 30 Sep 2026): the hero with the pocket demo and the call to action, three
// steps, four features, one pricing block, six questions. Guides are linked from the FAQ and the footer.

const R = config.requirements;

const a2Markup = a2File as unknown as string;

/** The two SVG symbols the demos draw with (the Farside mark and the Mac pointer), from the hero lab. In the hero, so
 * they sit outside the content-visibility sections below. */
const A2_SPRITE = raw(`<svg class="a2-sprite" width="0" height="0" aria-hidden="true" focusable="false">
  <symbol id="mk" viewBox="0 0 26 38"><g fill="#EDE8DF"><circle cx="3" cy="8" r="1.4"/><circle cx="7" cy="8" r="1.4"/><circle cx="3" cy="12" r="1.4"/><circle cx="7" cy="12" r="1.4"/><circle cx="11" cy="12" r="1.4"/><circle cx="3" cy="16" r="1.4"/><circle cx="7" cy="16" r="1.4"/><circle cx="11" cy="16" r="1.4"/><circle cx="15" cy="16" r="1.4"/><circle cx="3" cy="20" r="1.4"/><circle cx="7" cy="20" r="1.4"/><circle cx="11" cy="20" r="1.4"/><circle cx="15" cy="20" r="1.4"/><circle cx="19" cy="20" r="1.4"/><circle cx="3" cy="24" r="1.4"/><circle cx="7" cy="24" r="1.4"/><circle cx="11" cy="24" r="1.4"/><circle cx="15" cy="24" r="1.4"/><circle cx="19" cy="24" r="1.4"/><circle cx="23" cy="24" r="1.4"/><circle cx="3" cy="28" r="1.4"/><circle cx="7" cy="28" r="1.4"/><circle cx="11" cy="28" r="1.4"/><circle cx="3" cy="32" r="1.4"/><circle cx="11" cy="32" r="1.4"/><circle cx="15" cy="32" r="1.4"/><circle cx="15" cy="36" r="1.4"/></g><circle cx="3.2" cy="3.2" r="2.8" fill="#FF5B1F"/></symbol>
  <symbol id="ptr" viewBox="-1.5 -1.5 17 23"><path d="M0 0V16.6L4.1 12.8L6.8 19.1L9.7 17.9L7 11.7H12.7Z" fill="#000" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></symbol>
</svg>`);

/** A2's Mac scene (the desktop and its windows), which the hero's "From the pocket" demo steers. */
const i0 = a2Markup.indexOf('<div class="a2-scene">');
const i1 = a2Markup.indexOf('<div class="a2-view">');
if (i0 < 0 || i1 < 0) throw new Error("src/hero-a2/a2.html changed shape: cannot find the Mac scene");
const macScene = raw(a2Markup.slice(i0, i1).trim());

/**
 * The hero demo, variant 2 "From the pocket" from the hero lab (src/hero-pocket/): the phone rises on Farside's
 * Home screen, connects, and the view pulls back to the Mac it steers. The box is sized by CSS alone; the
 * script fits the stage into it and builds the phone. Decorative, so the drawing is hidden from screen readers.
 */
const pocketDemo = html`<figure class="hero-demo lx" role="img" aria-label="Demo: an iPhone opens Farside and connects to a Mac. The view pulls back to the Mac it now steers, with an orange outline around the part shown on the phone.">
  <div class="lx-stage" aria-hidden="true">
    <canvas class="lx-field"></canvas>
    <div class="lx-world">
      <div class="lx-mac">
        <div class="lx-lid"><div class="lx-lidf"><div class="lx-scr">
          ${macScene}
          <div class="lx-view"><i></i><i></i><i></i><i></i><b></b><b></b><b></b><b></b></div>
          <div class="lx-mptr"><svg viewBox="-1.5 -1.5 17 23"><use href="#ptr"/></svg></div>
        </div></div></div>
        <div class="lx-deck"></div>
        <div class="lx-base"></div>
      </div>
    </div>
    <canvas class="lx-fx"></canvas>
    <p class="lx-status"><span><i></i>Your iPhone is steering studio-mac</span></p>
  </div>
</figure>`;

/** The call to action for the current stage (site.config.ts `cta`): its line, then its button. #beta is linked from old URLs. */
function ctaBlock(): Html {
  return html`<div class="wl" id="beta">
  <p class="cta-note">${cta().note}</p>
  ${ctaButton()}
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

/**
 * The hero background (src/hero-bg/): a CSS poster from the first paint, then a WebGL shader of the same look.
 * Four looks on preview hosts, ?bg=reach|spectrum|aurora|bloom; everyone else gets config.look.heroBackground.
 */
const heroBg = html`<div class="hero-bg" data-bg="${config.look.heroBackground}" aria-hidden="true"><canvas></canvas></div>`;

const hero = html`<section class="hero" id="top" aria-labelledby="hero-title">
  ${heroBg}
  ${A2_SPRITE}
  <div class="hero-c w">
    <p class="eyebrow"><i></i>Farside · remote desktop for your Mac<i></i></p>
    <h1 class="h1" id="hero-title"><span class="ln dw"><span>Your Mac is far${pd}</span></span> <span class="ln dw"><span>Your reach <em>isn’t.</em></span></span></h1>
    <p class="sub">Use your Mac from your iPhone. Free on your own Wi‑Fi.</p>
    ${ctaBlock()}
  </div>
  ${pocketDemo}
  <div class="hero-foot w">${motionButton}</div>
</section>`;

/** A build-time dither illustration (decorative: the text says it all). */
function art(assets: Assets, key: string): Html {
  const i = assets.img[key];
  if (!i) return html`<span class="art art-ph" aria-hidden="true"></span>`;
  return html`<img class="art" src="${i.src}" width="${i.w}" height="${i.h}" alt="" loading="lazy" decoding="async">`;
}

const how = (assets: Assets) => html`<section class="sec" id="how" aria-labelledby="how-title">
  <div class="w">
    ${sh("how-title", "How it works", html`Three steps<span class="pd">,</span> <em>then</em> you’re in${pd}`)}
    <ol class="steps" role="list" data-rv>
      <li class="step">${art(assets, "art-step1")}<p class="n" aria-hidden="true">01</p><h3>Get Farside for Mac</h3><p>It’s free. Install it and open the pairing code.</p></li>
      <li class="step">${art(assets, "art-step2")}<p class="n" aria-hidden="true">02</p><h3>Pair your iPhone</h3><p>Scan the code, compare the code on both devices, then choose Allow on your Mac. No account.</p></li>
      <li class="step">${art(assets, "art-step3")}<p class="n" aria-hidden="true">03</p><h3>Reach your Mac</h3><p>Follow the permission prompts, then tap Connect to see your Mac.</p></li>
    </ol>
    <p class="req" data-rv="self">You’ll need ${R.mac}, and an iPhone with ${R.iphone}.</p>
  </div>
</section>`;

const features = (assets: Assets) => html`<section class="sec" id="features" aria-labelledby="features-title">
  <div class="w">
    ${sh("features-title", "What you get", html`Small screen${pd} <em>Whole</em> Mac${pd}`)}
    <ul class="feats" role="list" data-rv>
      <li class="feat">${art(assets, "art-feat-pad")}<h3>The screen is a trackpad</h3><p>Slide to move the pointer. Tap to click.</p></li>
      <li class="feat">${art(assets, "art-feat-zoom")}<h3>Zoom in on small text</h3><p>Pinch to zoom in on any part of your Mac.</p></li>
      <li class="feat">${art(assets, "art-feat-voice")}<h3>Type from your phone</h3><p>Open the keyboard to send text to your Mac. Protected fields and system prompts have limits.</p></li>
      <li class="feat">${art(assets, "art-feat-trust")}<h3>You approve access</h3><p>Your Mac asks before a new iPhone can connect, and pairs only with the devices you approve.</p></li>
    </ul>
  </div>
</section>`;

/** No prices until config.pricing.final: Anywhere pricing is being re-decided before 23 Oct 2026. */
const pricing = html`<section class="sec" id="pricing" aria-labelledby="pricing-title">
  <div class="w">
    ${sh("pricing-title", "Plans", html`Free at home${pd} <em>Anywhere</em> for away${pd}`)}
    <div class="price" data-rv>
      <div class="price-col">
        <h3 class="cap">Free at home</h3>
        <p class="amt">Free</p>
        <p>When your Mac and your iPhone are on the same Wi‑Fi. No account, no ads.</p>
      </div>
      <div class="price-col any">
        <h3 class="cap">Farside Anywhere</h3>
        <p class="amt">Soon</p>
        <p>Use your Mac when you’re away from home. A paid plan, sold in the app through Apple. Not on sale yet.</p>
      </div>
    </div>
    <p class="fine" data-rv="self">Anywhere pricing will be announced before it goes on sale.</p>
  </div>
</section>`;

const QAS: QA[] = [
  {
    q: "Is it really free?",
    a: html`<p>Yes, when your Mac and your iPhone are on the same Wi‑Fi. No account, no ads. Using your Mac away from home is a paid plan, Farside Anywhere, which isn’t on sale yet.</p>`,
  },
  {
    q: "What do I need?",
    a: html`<p>${R.mac}, with Farside for Mac (free). And an iPhone with ${R.iphone}. Macs with an Intel processor aren’t supported. The <a href="/support#setup">support page</a> shows each step.</p>`,
  },
  {
    q: "Can I use an iPad?",
    a: html`<p>Farside 1.0 is designed for iPhone. iPads can run the iPhone app in compatibility mode; a dedicated iPad experience is outside this release’s scope.</p>`,
  },
  {
    q: "Can anyone else see my screen?",
    a: html`<p>Your Mac approves pairing before an iPhone can start a trusted-device session. You can remove a pairing or stop sharing from the Mac’s menu bar at any time. More in the <a href="/privacy">privacy policy</a>.</p>`,
  },
  {
    q: "Does my Mac need to be awake?",
    a: html`<p>Yes. Your Mac must be awake, unlocked and logged in. Keep-awake can help prevent idle sleep while sharing on power; manual sleep, closing a laptop lid, a restart or loss of power can interrupt access. Farside can’t log in for you.</p>`,
  },
  {
    q: "When can I get it?",
    a: html`<p>${ctaSentence()}</p>`,
  },
  {
    q: "Is Farside the same as farside.app?",
    a: html`<p>No. Farside at getfarside.com is a remote desktop app for your Mac, made by ${config.contact.legalName ?? "an independent developer"}. It isn’t related to farside.app or to other products with a similar name. <a href="/about">About Farside</a>.</p>`,
  },
];

const faq = html`<section class="sec" id="faq" aria-labelledby="faq-title">
  <div class="w faq-w">
    ${sh("faq-title", "FAQ", html`Questions<span class="pd">,</span> <em>answered.</em>`)}
    <div class="faq" data-rv>
      ${QAS.map(({ q, a }) => html`<details><summary><span>${q}</span><span class="pm" aria-hidden="true"></span></summary><div class="a">${a}</div></details>`)}
    </div>
    <p class="more" data-rv="self">More answers on the <a href="/support">support page</a>.</p>
  </div>
</section>`;

const DESC =
  "Control your Mac from your iPhone. See your Mac’s screen and use it with your finger. Free on the same Wi‑Fi, with no account.";

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
      homeCss: true,
      jsonLd: graph(
        webPage({ path: "/", name: "Farside: Control your Mac from your iPhone", description: DESC, image }),
        softwareApplication(image),
        faqPage("/", QAS),
      ),
    },
    assets,
    html`${hero}\n${how(assets)}\n${features(assets)}\n${pricing}\n${faq}`,
  );
}
