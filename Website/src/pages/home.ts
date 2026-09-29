import { config } from "../../site.config";
import { html, pd, raw, type Html } from "../lib/html";
import { markSvg } from "../lib/mark";
import { betaHref, email, guideCards, icon, ogUrl, page, storeButtons, type Assets } from "./layout";
import { faqPage, graph, softwareApplication, webPage, type QA } from "./schema";

const P = config.pricing;
const R = config.requirements;

function primaryCta(): Html {
  const dl = config.launch.macDownloadUrl;
  if (dl) return html`<a class="cta" href="${dl}">Download for Mac <span class="arr">${icon.arrow}</span></a>`;
  return html`<a class="cta" href="#beta">Join the beta <span class="arr">${icon.arrow}</span></a>`;
}

function heroCtas(): Html {
  // After launch the primary button is the Mac download, so only the App Store badge sits beside it.
  return html`${primaryCta()}${storeButtons({ mac: !config.launch.macDownloadUrl })}`;
}

const hero = html`<section class="hero" aria-labelledby="hero-title">
  <canvas class="hero-cv" aria-hidden="true"></canvas>
  <div class="grain" aria-hidden="true"></div>
  <div class="hero-c w">
    <p class="eyebrow"><i></i>Remote control for your own Mac<i></i></p>
    <h1 class="h1" id="hero-title"><span class="ln"><span>Your Mac is far${pd}</span></span><span class="ln"><span>Your reach <em>isn’t.</em></span></span></h1>
    <p class="sub">Farside puts your Mac on your iPhone or iPad and turns the whole screen into a trackpad. One finger points. A tap clicks. No account, no cables, no awkward lunge across the couch.</p>
    <div class="ctas">${heroCtas()}</div>
  </div>
  <div class="hero-space" aria-hidden="true"></div>
  <p class="corner l cap" aria-hidden="true">Phone<b>side</b></p>
  <p class="corner r cap" aria-hidden="true">Mac<b>side</b></p>
  <p class="gapr" aria-hidden="true"><span class="long">Distance to your Mac · </span><span class="short">Gap · </span><b>8,421 km</b></p>
  <div class="stats-wrap">
    <button class="motion" type="button" hidden>
      <svg class="ico i-pause" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M8 5v14M16 5v14"/></svg>
      <svg class="ico i-play" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M7 5l12 7-12 7z"/></svg>
      <span class="lbl">Pause motion</span>
    </button>
    <ul class="stats w" aria-label="Farside in four numbers">
      <li class="stat"><b><span data-count="0" data-from="12">0</span></b><span>Accounts to make</span></li>
      <li class="stat"><b><span data-count="1" data-from="9">1</span></b><span>QR code to pair</span></li>
      <li class="stat"><b><span data-count="2" data-from="0">2</span></b><span>Ways the clipboard goes</span></li>
      <li class="stat"><b><small>CA$</small><span data-count="0" data-from="99">0</span></b><span>On your home network</span></li>
    </ul>
  </div>
</section>`;

/** A build-time dither illustration (decorative: the step text says it all). */
function art(assets: Assets, key: string): Html {
  const i = assets.img[key];
  if (!i) return html`<span class="art-ph" aria-hidden="true"></span>`;
  return html`<img class="art" src="${i.src}" width="${i.w}" height="${i.h}" alt="" loading="lazy" decoding="async">`;
}

const how = (assets: Assets) => html`<section class="sec" id="how" aria-labelledby="how-title">
  <div class="w">
    <div class="sh">
      <div><p class="cap">How it works</p><h2 class="h2" id="how-title">Three touches${pd}<br> <em>Then</em> you’re in${pd}</h2></div>
      <p>No account to make, nothing to forward on your router and no cables. It takes about as long as finding your phone charger.</p>
    </div>
    <ol class="steps" role="list">
      <li class="step">
        ${art(assets, "art-step1")}
        <p class="n" aria-hidden="true">01</p>
        <h3>Put the helper on your Mac</h3>
        <p>A free download that sits quietly in the menu bar. It asks for two permissions, Screen Recording and Accessibility, and points at the exact switches.</p>
      </li>
      <li class="step">
        ${art(assets, "art-step2")}
        <p class="n" aria-hidden="true">02</p>
        <h3>Scan, then approve</h3>
        <p>Point your iPhone at the code on your Mac, then approve the phone on the Mac. That’s the pairing. Nothing to sign up for.</p>
      </li>
      <li class="step">
        ${art(assets, "art-step3")}
        <p class="n" aria-hidden="true">03</p>
        <h3>Tap Connect</h3>
        <p>Your Mac appears and the whole screen becomes a trackpad. Slide to point, tap to click, two fingers to scroll, pinch to zoom.</p>
      </li>
    </ol>
  </div>
</section>`;

const qr = (() => {
  // A decorative, deterministic dot-matrix "code" (not a real QR code).
  let d = "";
  for (let y = 0; y < 11; y++)
    for (let x = 0; x < 11; x++) {
      const finder = (x < 3 && y < 3) || (x > 7 && y < 3) || (x < 3 && y > 7);
      if (finder || (x * 7 + y * 13 + x * y) % 5 < 2) d += `M${x * 10 + 1} ${y * 10 + 1}h8v8h-8z`;
    }
  return raw(`<svg class="qr" viewBox="0 0 110 110" aria-hidden="true" focusable="false"><path fill="currentColor" d="${d}"/></svg>`);
})();

const features = html`<section class="sec" id="features" aria-labelledby="features-title">
  <div class="w">
    <div class="sh">
      <div><p class="cap">What it does</p><h2 class="h2" id="features-title">Small screen${pd}<br> <em>Whole</em> Mac${pd}</h2></div>
      <p>Your actual Mac, not a watered-down version of it, steered with one thumb. The picture stays sharp; the dots are only decoration.</p>
    </div>
    <ul class="bento" role="list">
      <li class="card wide">
        <div class="viz v-track amb" aria-hidden="true">
          <div class="viz-dots htone"></div>
          <span class="finger"></span>
          <span class="ptr">${icon.pointer}<i class="rip"></i><i class="tip"></i></span>
          <span class="cap">Tap anywhere · it clicks at the pointer</span>
        </div>
        <h3>The whole screen is a trackpad</h3>
        <p>Slide anywhere to move the pointer, tap to click, two fingers to scroll. <b>Every click lands with a haptic tap</b>, so you feel it happen instead of squinting to check.</p>
      </li>
      <li class="card">
        <div class="viz v-sizes" aria-hidden="true">
          <figure><svg width="13" height="18" viewBox="0 0 26 36">${raw('<path d="M2 2v28l7.5-7 5 11 5-2.3-5-10.7H25z" fill="#0A0A0A" stroke="#EDE8DF" stroke-width="2.4" stroke-linejoin="round"/>')}</svg><figcaption>S</figcaption></figure>
          <figure><svg width="19" height="26" viewBox="0 0 26 36">${raw('<path d="M2 2v28l7.5-7 5 11 5-2.3-5-10.7H25z" fill="#0A0A0A" stroke="#EDE8DF" stroke-width="2.4" stroke-linejoin="round"/>')}</svg><figcaption>M</figcaption></figure>
          <figure><svg width="26" height="36" viewBox="0 0 26 36">${raw('<path d="M2 2v28l7.5-7 5 11 5-2.3-5-10.7H25z" fill="#0A0A0A" stroke="#EDE8DF" stroke-width="2.4" stroke-linejoin="round"/>')}</svg><figcaption>L</figcaption></figure>
          <figure class="xl"><svg width="36" height="50" viewBox="0 0 26 36">${raw('<path d="M2 2v28l7.5-7 5 11 5-2.3-5-10.7H25z" fill="#0A0A0A" stroke="#EDE8DF" stroke-width="2.4" stroke-linejoin="round"/>')}</svg><figcaption>XL</figcaption></figure>
        </div>
        <h3>A pointer you can actually find</h3>
        <p>Big, sharp and drawn by your phone, not smeared across a video frame. Pick Small, Medium, Large or Extra Large.</p>
      </li>
      <li class="card">
        <div class="viz v-zoom" aria-hidden="true">
          <div class="page"><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i></div>
          <div class="lens"><i></i><i></i><i></i><i></i>${raw('<svg viewBox="0 0 26 36"><path d="M2 2v28l7.5-7 5 11 5-2.3-5-10.7H25z" fill="#0A0A0A" stroke="#EDE8DF" stroke-width="2.4" stroke-linejoin="round"/></svg>')}</div>
          <span class="cap">Pinch · the view follows</span>
        </div>
        <h3>Zoom that follows you</h3>
        <p>Pinch in on tiny text and the view follows your pointer around, so you’re never hunting for where you left it.</p>
      </li>
      <li class="card">
        <div class="viz v-voice amb" aria-hidden="true">
          <span class="wave"><i></i><i></i><i></i><i></i><i></i><i></i><i></i></span>
          <span class="keys"><kbd>⌘</kbd><kbd>⌥</kbd><kbd>⌃</kbd><kbd>⇧</kbd></span>
          <span class="cap">Listening · speak, then Done</span>
        </div>
        <h3>Talk. It types.</h3>
        <p>Tap the mic, say it, tap Done, and the words land on your Mac. Speech is recognized on your iPhone; the audio never leaves it. Or type, with ⌘ ⌥ ⌃ ⇧ right there.</p>
      </li>
      <li class="card">
        <div class="viz v-clip" aria-hidden="true">
          <span class="dev phone">iPhone</span>
          <span class="swap">${raw('<svg viewBox="0 0 40 14"><path d="M2 4h34M31 0l5 4-5 4" fill="none" stroke="currentColor" stroke-width="1.6"/></svg><svg viewBox="0 0 40 14"><path d="M38 10H4M9 6l-5 4 5 4" fill="none" stroke="currentColor" stroke-width="1.6"/></svg>')}</span>
          <span class="dev mac">Mac</span>
          <span class="cap">Copy here · paste there</span>
        </div>
        <h3>Clipboard, both ways</h3>
        <p>Copy on the Mac and paste on your phone, or the other way round. Only when you ask: nothing syncs in the background.</p>
      </li>
      <li class="card">
        <div class="viz v-pair" aria-hidden="true">
          ${qr}<span class="frame"></span>
          <span class="cap">Scan · approve · done</span>
        </div>
        <h3>A QR code, not an account</h3>
        <p>Scan the code your Mac shows and approve the phone there. No sign-up, no password, no email address to confirm.</p>
      </li>
      <li class="card wide">
        <div class="viz v-trust" aria-hidden="true">
          <div class="viz-dots htone"></div>
          <div class="ask">
            <p>${icon.phone}<span>An iPhone wants to connect to this Mac.</span></p>
            <div><span>Decline</span><span>Allow</span></div>
          </div>
          <span class="cap">You approve every phone</span>
        </div>
        <h3>Encrypted end to end</h3>
        <p>Your screen, keystrokes and voice travel between your own devices, encrypted. You approve every phone on the Mac, and <b>Stop Sharing</b> in the menu bar ends the session immediately. Your Mac only shares its screen while a phone you approved is connected.</p>
      </li>
    </ul>
  </div>
</section>`;

const agents = html`<section class="sec" id="agents" aria-labelledby="agents-title">
  <div class="w agents">
    <div>
      <p class="beta-tag">Beta · arrives with the first release</p>
      <h2 class="h2" id="agents-title">When your agent needs <em>you</em>${pd}</h2>
      <p class="lead">Leave an AI coding agent working on your Mac and walk away. If it stops to ask for permission, or needs you to sign in to something, Farside taps you on the shoulder. Tap the alert and you’re looking at your Mac, ready to answer.</p>
      <ul class="ticks" role="list">
        <li><span><b>Off until you turn it on,</b> on your Mac.</span></li>
        <li><span><b>Says who, not what.</b> The alert names the agent that needs you. No prompts, file names or screen content ride along.</span></li>
        <li><span><b>Same session as always:</b> your paired phone, encrypted end to end.</span></li>
        <li><span><b>It’s a beta.</b> Expect rough edges, and please tell us about them.</span></li>
      </ul>
    </div>
    <div class="lock" aria-hidden="true">
      <div class="viz-dots htone"></div>
      <p class="time">9<span class="pd">:</span>41</p>
      <p class="date cap">Tuesday · nowhere near your desk</p>
      <div class="note"><span class="app">${raw(markSvg(18))}</span><p class="top"><span>Farside</span><span>now</span></p><b>Your coding agent needs you</b><span class="msg">It’s waiting on your Mac. Tap to take a look.</span></div>
      <div class="note second"><span class="app">${raw(markSvg(18))}</span><p class="top"><span>Farside</span><span>2 min ago</span></p><b>Your coding agent needs you</b><span class="msg">Tap to open your Mac.</span></div>
    </div>
  </div>
</section>`;

const pricing = html`<section class="sec" id="pricing" aria-labelledby="pricing-title">
  <div class="w">
    <div class="sh">
      <div><p class="cap">Pricing</p><h2 class="h2" id="pricing-title">Free at home${pd}<br> A plan for <em>away</em>${pd}</h2></div>
      <p>When your iPhone or iPad and your Mac share a network, Farside is free. Reaching your Mac over the internet is what the Anywhere plan is for. No ads either way.</p>
    </div>
    <div class="price">
      <article class="plan" aria-labelledby="plan-free">
        <p class="cap">Free at home</p>
        <h3 id="plan-free">On your own network. <em>Free.</em></h3>
        <p class="amt"><span class="cur">CA$</span>0</p>
        <p class="per">Not a trial in a trench coat.</p>
        <ul role="list">
          <li><span>Your iPhone or iPad and Mac on the same network</span></li>
          <li><span>Trackpad, keyboard and voice typing</span></li>
          <li><span>Clipboard both ways</span></li>
          <li><span>No account</span></li>
        </ul>
        <div class="foot">${primaryCta()}</div>
      </article>
      <article class="plan any" aria-labelledby="plan-any">
        <p class="cap">Anywhere</p>
        <h3 id="plan-any">Past your <em>front door.</em></h3>
        <div class="tog" role="group" aria-label="Billing period"><button type="button" aria-pressed="false" data-bill="mo">Monthly</button><button type="button" aria-pressed="true" data-bill="yr">Yearly</button></div>
        <div class="price-box" aria-live="polite">
          <p class="amt" data-bill="yr"><span class="cur">CA$</span>49<span class="pd">.</span>99<small> /yr</small></p>
          <p class="per" data-bill="yr">${P.yearlyPerMonth} a month · <b>save ${P.yearlySaving}</b></p>
          <p class="amt" data-bill="mo" hidden><span class="cur">CA$</span>5<span class="pd">.</span>99<small> /mo</small></p>
          <p class="per" data-bill="mo" hidden>Month to month. Leave whenever.</p>
        </div>
        <ul role="list">
          <li><span>Everything in Free at home</span></li>
          <li><span>Reach your Mac over the internet, on cellular or somebody else’s Wi-Fi</span></li>
          <li><span>No router settings, port forwarding or VPN</span></li>
          <li><span>${P.trialDays} days free to start; cancel in your Apple Account settings</span></li>
        </ul>
        <div class="foot"><p>Subscribe inside the iPhone or iPad app <span class="soon">Coming soon</span></p></div>
      </article>
    </div>
    <p class="fine">Planned launch pricing, in Canadian dollars: Anywhere is ${P.monthly} a month or ${P.yearly} a year after a ${P.trialDays}-day free trial. The App Store shows the price in your currency before you subscribe. Anywhere is sold only inside the app, through Apple; this website never takes payment.</p>
  </div>
</section>`;

const QAS: QA[] = [
  {
    q: "Is it really free?",
    a: html`<p>Yes, on your own network. When your iPhone or iPad and your Mac are on the same local network, Farside is free, with no account and no ads. Reaching your Mac over the internet needs the Anywhere plan: ${P.monthly} a month or ${P.yearly} a year (planned), with a ${P.trialDays}-day free trial.</p>`,
  },
  {
    q: "What do I need?",
    a: html`<p>A Mac running ${R.mac} with the free Farside helper, and an iPhone on ${R.iphone} or an iPad on ${R.ipad} with the Farside app. These are the planned requirements; we’ll confirm them at launch. The <a href="/control-mac-from-iphone">setup guide</a> walks through it.</p>`,
  },
  {
    q: "Do I have to make an account?",
    a: html`<p>No. You pair by scanning a code on your Mac and approving the phone there. Your devices remember each other, and there’s no Farside account to forget the password to.</p>`,
  },
  {
    q: "Can anyone else see my screen?",
    a: html`<p>No. The picture, your keystrokes and your voice travel between your own devices, encrypted end to end. Our servers help your devices find each other and, on Anywhere, pass along encrypted traffic they can’t read. Voice is recognized on your iPhone and only the text goes to your Mac.</p><p>The details are in the <a href="/privacy">privacy policy</a>.</p>`,
  },
  {
    q: "Why isn’t the Mac helper on the Mac App Store?",
    a: html`<p>To turn taps into clicks it needs Accessibility and Screen Recording permissions that Mac App Store apps can’t use. So it’s a free download from this website, signed with an Apple Developer ID, notarized by Apple, and it keeps itself up to date.</p>`,
  },
  {
    q: "Does my Mac need to be awake?",
    a: html`<p>Yes. Farside can’t wake a sleeping Mac or log in for you. While a phone is connected it keeps the Mac awake; if the Mac locks, sleeps or restarts, sharing stops and your phone tells you why. After a restart, log in once.</p>`,
  },
  { q: "Does it work with Windows or Android?", a: html`<p>No. Farside is for Macs, steered from an iPhone or iPad.</p>` },
  {
    q: "How does billing work for Anywhere?",
    a: html`<p>Anywhere is an auto-renewing subscription you buy inside the iPhone or iPad app, through Apple, after a ${P.trialDays}-day free trial. Cancel any time in Settings › your name › Subscriptions. Refunds are handled by Apple.</p>`,
  },
  {
    q: "How is Farside different from other remote desktop apps?",
    a: html`<p>It’s built around a trackpad rather than a touchscreen, with click haptics; it needs no account; and it’s free without a time limit on your own network. The <a href="/compare">comparison page</a> lines it up against Astropad Workbench, Jump Desktop, Screens and Remote Mac Desktop Control.</p>`,
  },
  {
    q: "When can I get it?",
    a: html`<p>Soon. Farside is in beta testing and there’s no launch date yet; we’d rather it just works. <a href="#beta">Join the beta</a> to try it first.</p>`,
  },
];

const faq = html`<section class="sec" id="faq" aria-labelledby="faq-title">
  <div class="w">
    <div class="sh">
      <div><p class="cap">FAQ</p><h2 class="h2" id="faq-title">Questions<span class="pd">,</span> <em>answered</em>${pd}</h2></div>
      <p>Something else on your mind? The <a class="link" href="/support">support page</a> covers setup, every message the app can show, and how to reach a human.</p>
    </div>
    <div class="faq">
      ${QAS.map(({ q, a }) => html`<details><summary><span>${q}</span><span class="pm" aria-hidden="true"></span></summary><div class="a">${a}</div></details>`)}
    </div>
  </div>
</section>`;

function betaBand(): Html {
  const href = betaHref();
  const ask = href
    ? html`<a class="cta" href="${href}">Email to join the beta <span class="arr">${icon.arrow}</span></a>`
    : html`<p class="soon">Beta sign-up address coming soon</p>`;
  return html`<section class="sec band" id="beta" aria-labelledby="beta-title">
  <div class="w">
    <div class="band-mark" aria-hidden="true">${raw(markSvg(64))}</div>
    <h2 class="h2" id="beta-title">Coming <em>soon.</em></h2>
    <p class="lead">Farside is in beta testing. There’s no launch date yet: we’d rather it just works. Want in early? Beta testers get a TestFlight invite for iPhone and iPad and a notarized build for their Mac.</p>
    <div class="row">${ask}${storeButtons()}</div>
    <p class="how">Email ${email("beta")} with the Mac and the iPhone or iPad you’d test on.</p>
  </div>
</section>`;
}

const guides = html`<section class="sec" id="guides" aria-labelledby="guides-title">
  <div class="w">
    <div class="sh">
      <div><p class="cap">Guides</p><h2 class="h2" id="guides-title">Read up<span class="pd">,</span><br> <em>then</em> reach${pd}</h2></div>
      <p>Step-by-step setup, every gesture, how the connection works, and how Farside compares with other remote apps.</p>
    </div>
    ${guideCards()}
  </div>
</section>`;

const DESC =
  "See and control your own Mac from your iPhone or iPad. The whole screen is a trackpad. Free on your own network, no account, encrypted end to end.";

export function homePage(assets: Assets) {
  const image = ogUrl(assets, "home");
  return page(
    {
      path: "/",
      title: "Farside: Remote Desktop · Control your Mac from iPhone",
      ogTitle: "Farside · Your Mac is far. Your reach isn’t.",
      description: DESC,
      script: "home",
      bodyClass: "home",
      og: "home",
      jsonLd: graph(
        webPage({ path: "/", name: "Farside: Remote Desktop · Control your Mac from iPhone", description: DESC, image }),
        softwareApplication(image),
        faqPage("/", QAS),
      ),
    },
    assets,
    html`${hero}\n${how(assets)}\n${features}\n${agents}\n${pricing}\n${faq}\n${guides}\n${betaBand()}`,
  );
}
