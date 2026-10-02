// Support: setup, gestures, and plain-language troubleshooting. Message wording follows the error rewrites in
// Docs/research/2026-09-28-round2/UX-AUDIT.md (§1, "Error copy rewrites") and the Reach voice: what happened,
// why if known, one fix. Update these together with the app's strings.

import { config } from "../../site.config";
import { html, type Html } from "../lib/html";
import { ownerComment, pageHero } from "./doc";
import { figure, gestureTable } from "./guide";
import { betaHref, detail, email, icon, ogUrl, page, type Assets } from "./layout";
import { breadcrumbs, faqPage, graph, howTo, webPage, type QA } from "./schema";

const R = config.requirements;
const PATH = "/support";
const DESC =
  "Set up Farside, learn the gestures and fix a connection. Plain-language answers for every message in the app, billing help for Anywhere, and how to reach a person.";

type Msg = { says: string; means: string; fix: Html };

const MESSAGES: Msg[] = [
  {
    says: "Couldn’t reach your Mac.",
    means: "Your Mac may be asleep or offline, or Farside isn’t running on it.",
    fix: html`Wake the Mac, check that the Farside icon is in its menu bar, then tap <b>Try Again</b>.`,
  },
  {
    says: "Your Mac isn’t available right now.",
    means: "The Mac isn’t sharing at the moment.",
    fix: html`Check that it’s awake and logged in, and that Farside is in its menu bar with sharing on.`,
  },
  {
    says: "Your Mac is napping.",
    means: "It dozed off, so it can’t hear your phone.",
    fix: html`Tap any key on the Mac or open its lid, then try again. To nap less, turn on <b>Wake for network access</b> in the Mac’s Battery or Energy settings.`,
  },
  {
    says: "Farside is still closing your last session.",
    means: "The previous connection hasn’t finished shutting down.",
    fix: html`Wait a few seconds and try again.`,
  },
  {
    says: "Couldn’t verify this Mac.",
    means: "The secure handshake between your devices didn’t complete.",
    fix: html`Try again. If it keeps happening, pair the phone again from the Farside menu on your Mac.`,
  },
  {
    says: "The connection glitched, so Farside ended the session to keep your Mac safe.",
    means: "Something arrived that didn’t look right, so Farside stopped instead of guessing.",
    fix: html`Reconnect. Nothing on your Mac was changed by the glitch.`,
  },
  {
    says: "Reconnecting… (2 of 5)",
    means: "The network blinked. Farside is retrying by itself and keeps your zoom and position.",
    fix: html`Give it a moment, or tap <b>Cancel</b> to stop trying.`,
  },
  {
    says: "You left Farside, so your Mac’s screen is hidden.",
    means: "Your Mac’s screen is covered whenever Farside isn’t on screen, so it can’t be seen in the app switcher.",
    fix: html`Come back to Farside; it reconnects without pairing again if you return within a few minutes.`,
  },
  {
    says: "Waiting for your Mac’s screen…",
    means: "The connection is up and the first picture is on its way.",
    fix: html`Give it a second. If it doesn’t arrive, end the session and connect again.`,
  },
  {
    says: "Your Mac stopped sharing its screen.",
    means: "macOS may be asking to renew Screen Recording permission, or someone chose Stop Sharing on the Mac.",
    fix: html`On the Mac, open Farside from the menu bar and allow Screen Recording if macOS asks.`,
  },
  {
    says: "Reconnecting the picture. Controls are paused.",
    means: "The picture dropped for a moment, so taps are held back rather than sent blind.",
    fix: html`Wait a moment; controls come back with the picture.`,
  },
  {
    says: "Mouse and keyboard are off on your Mac.",
    means: "You can see the Mac but not steer it: control is turned off, or Accessibility access is missing.",
    fix: html`On the Mac, turn on <b>Allow control</b> in the Farside menu and check Farside is allowed under <b>Privacy &amp; Security › Accessibility</b>.`,
  },
  {
    says: "Update Farside on your Mac to change picture quality.",
    means: "Your phone is newer than the Mac helper.",
    fix: html`Choose <b>Check for Updates…</b> in the Farside menu on your Mac.`,
  },
  {
    says: "That’s too long to send at once.",
    means: "There’s a size limit on each piece of text you send or dictate.",
    fix: html`Send it in two parts.`,
  },
  {
    says: "That code has expired.",
    means: "Pairing codes only last about two minutes, for safety.",
    fix: html`On your Mac, choose <b>New Code</b>, then scan again.`,
  },
  {
    says: "That isn’t a Farside code.",
    means: "The camera found a QR code, just not ours.",
    fix: html`Scan the code shown in Farside’s pairing window on your Mac.`,
  },
  {
    says: "Nobody approved this iPhone on the Mac in time.",
    means: "Pairing needs a yes on the Mac, and it waited about a minute.",
    fix: html`Try again and choose <b>Allow</b> on the Mac when it asks.`,
  },
  {
    says: "Your Mac isn’t on this network.",
    means: "Free use works when your phone and Mac share a network. Reaching it over the internet needs the Anywhere plan.",
    fix: html`Join the same Wi-Fi as your Mac, or try Anywhere free for ${String(config.pricing.trialDays)} days.`,
  },
];

const SETUP: { name: string; text: string; body: Html }[] = [
  {
    name: "Put the helper on your Mac",
    text: `Download Farside for Mac, open it and move it to Applications if it asks. It lives in the menu bar and needs ${R.mac}.`,
    body: html`${config.launch.macDownloadUrl ? html`<a href="${config.launch.macDownloadUrl}">Download Farside for Mac</a>` : html`Download Farside for Mac from this website <span class="placeholder">(coming soon)</span>`}, open it, and move it to Applications if it asks. It lives in the menu bar. You need ${R.mac}.`,
  },
  {
    name: "Allow two permissions",
    text: "Allow Screen Recording, so your iPhone can see the screen, and Accessibility, so taps become clicks. The setup window notices each switch by itself.",
    body: html`Screen Recording, so your iPhone can see the screen, and Accessibility, so taps become clicks and typing becomes typing. Farside opens the right settings page; flip the switch and the setup window notices by itself. macOS may ask you to quit and reopen Farside once.`,
  },
  {
    name: "Get the app on your iPhone or iPad",
    text: `Get Farside from the App Store. You need ${R.iphone} or ${R.ipad}.`,
    body: html`${config.launch.appStoreUrl ? html`<a href="${config.launch.appStoreUrl}">Get Farside from the App Store</a>` : html`Get Farside from the App Store <span class="placeholder">(coming soon)</span>`}. You need ${R.iphone} or ${R.ipad}.`,
  },
  {
    name: "Pair",
    text: "On the Mac, choose Pair a Phone in the Farside menu. In the app, tap Scan and point the camera at the code, then choose Allow on the Mac.",
    body: html`On the Mac, choose <b>Pair a Phone…</b> in the Farside menu. In the app, tap <b>Scan</b> and point the camera at the code. Then choose <b>Allow</b> on the Mac. No account, no password.`,
  },
  {
    name: "Allow Local Network on the phone",
    text: "When iOS asks to find devices on your local network, choose Allow. That's how your phone finds your Mac at home.",
    body: html`When iOS asks to find devices on your local network, choose Allow. That’s how your phone finds your Mac at home.`,
  },
  {
    name: "Tap Connect",
    text: "Tap Connect and your Mac appears. The first time, a short practice pad shows you how to steer.",
    body: html`Your Mac appears. The first time, a short practice pad shows you how to steer; nothing you do there reaches the Mac.`,
  },
];

const OPEN_ITEMS = [
  "Contact block: support email, phone, postal address and response time (config.contact). Apple requires real contact details on the Support URL.",
  "Check every message below against the app's shipping strings; they follow the UX-AUDIT.md rewrites with the PocketDesk name replaced by Farside.",
  "Gesture list follows Docs/research/2026-09-28/GESTURE-MAP.md; physical gesture acceptance is still pending.",
  "Menu item names (Pair a Phone…, New Code, Allow control, Check for Updates…) must match the shipping Mac helper.",
];

const cantConnect = html`<ol>
  <li>Is the Mac awake and logged in? Farside can’t wake a sleeping Mac or get past the login screen.</li>
  <li>Is the Farside icon in the Mac’s menu bar, with sharing on?</li>
  <li>Are your phone and Mac on the same network? Or, away from home, is Anywhere active?</li>
  <li>Is Local Network allowed for Farside on the phone? Check <b>Settings › Privacy &amp; Security › Local Network</b>.</li>
  <li>Still stuck? Quit Farside on the Mac, open it again, and reconnect. Then write to us.</li>
</ol>`;

const permissions = html`<p>If you flipped the switch but Farside still says it can’t see or control the Mac, macOS may be holding on to an old permission.</p>
<ol>
  <li>Quit Farside from its menu bar, open it again and check the setup window.</li>
  <li>Still not detected? Open <b>System Settings › Privacy &amp; Security</b>, find Farside under Screen &amp; System Audio Recording (or Accessibility), select it and remove it with the <b>−</b> button.</li>
  <li>Add it back with <b>+</b>, choosing Farside in Applications, and turn it on.</li>
  <li>Reopen Farside. The setup window updates by itself.</li>
</ol>
<p>macOS sometimes asks again, every so often, whether Farside may keep recording the screen. Say yes on the Mac and sharing picks up where it left off.</p>`;

const billing = html`<ul>
  <li><b>Try it:</b> Anywhere starts with a ${config.pricing.trialDays}-day free trial, then ${config.pricing.monthly} a month or ${config.pricing.yearly} a year (planned pricing, Canadian dollars).</li>
  <li><b>Cancel or change plan:</b> Settings › your name › Subscriptions on your iPhone or iPad. Cancel at least 24 hours before the renewal date to avoid the next charge.</li>
  <li><b>Refunds:</b> Apple handles them. Request one at <a href="https://reportaproblem.apple.com" rel="noopener">reportaproblem.apple.com</a>.</li>
  <li><b>New phone?</b> Use <b>Restore Purchases</b> in the app’s settings.</li>
  <li>This website never asks for payment details.</li>
</ul>`;

function contact(): Html {
  const beta = betaHref();
  return html`<div class="contact-card">
  <dl>
    <div><dt>Email</dt><dd>${email("support")}</dd></div>
    <div><dt>Phone</dt><dd>${detail(config.contact.phone, "phone number")}</dd></div>
    <div><dt>Post</dt><dd>${detail(config.contact.legalName, "legal name")}<br>${detail(config.contact.postalAddress, "postal address")}</dd></div>
    <div><dt>First reply</dt><dd>${detail(config.contact.responseTime, "within two business days")}</dd></div>
    <div><dt>Security reports</dt><dd>${email("security")}</dd></div>
  </dl>
</div>
<p>To help us help you, include what you tried, what the message said, your Mac and iPhone or iPad models, their macOS and iOS versions, and whether both were on the same network. Please don’t send passwords or screenshots of private content.</p>
${beta ? html`<p>Want to test new builds early? <a href="${beta}">Join the beta</a>.</p>` : ""}`;
}

const MSG_QAS: QA[] = MESSAGES.map((m) => ({
  q: `What does “${m.says}” mean in Farside?`,
  a: html`<p>${m.means}</p><p>Fix: ${m.fix}</p>`,
}));

export function supportPage(assets: Assets) {
  const crumbs: [string, string][] = [
    ["Home", "/"],
    ["Support", PATH],
  ];
  const quick: [string, string, string][] = [
    ["#setup", "Set up Farside", "Mac helper, permissions, pairing"],
    ["#steer", "How to steer", "Every gesture on one list"],
    ["#cant-connect", "Can’t connect?", "A five-line checklist"],
    ["/status", "Service status", "Availability updates and help"],
    ["#messages", "What a message means", "Every message, with the fix"],
    ["#billing", "Anywhere and billing", "Trial, cancelling, refunds"],
    ["#contact", "Talk to a human", "Email, phone and post"],
  ];
  const body = html`${ownerComment("Owner checklist for /support:", OPEN_ITEMS)}
${pageHero({
  crumbs,
  cap: "Support",
  title: html`Help is <em>near.</em>`,
  lead: html`Setup steps, how to steer, what every message in the app means, and how to reach a person. Most fixes are <b>one step</b>.`,
})}
<div class="w">
  <ul class="quick" role="list" aria-label="Support topics">
    ${quick.map(([href, t, s]) => html`<li><a href="${href}"><span><b>${t}</b><small>${s}</small></span>${icon.chevron}</a></li>`)}
  </ul>
</div>
<div class="w doc single">
  <div class="prose">
    <h2 id="setup">Set up Farside</h2>
    <ol class="setup" role="list">${SETUP.map((s, i) => html`<li id="step-${i + 1}"><b>${s.name}.</b> ${s.body}</li>`)}</ol>
    <p>The <a href="/control-mac-from-iphone">illustrated setup guide</a> walks through the same steps with pictures.</p>
    <h2 id="steer">How to steer</h2>
    <p>Your finger doesn’t go to the button: the pointer is already on it, and a tap anywhere clicks right there. More in <a href="/iphone-as-mac-trackpad">using your iPhone as a Mac trackpad</a>.</p>
    ${gestureTable()}
    <p>Force Touch and pressure gestures can’t be done from a phone screen; use right-click or the app’s own buttons instead.</p>
    <h2 id="cant-connect">Can’t connect?</h2>
    ${cantConnect}
    <h3 id="permissions">The Mac says permissions are missing</h3>
    ${permissions}
    <h2 id="messages">What a message means</h2>
    <p>Every message in Farside says what happened and what to do. Here they all are, in case one needs more room.</p>
    ${figure(assets, "phone-nap", "Plain words and one fix, even when your Mac is asleep.")}
    <div class="msgs">
      ${MESSAGES.map(
        (m) =>
          html`<details><summary><q>${m.says}</q><span class="pm" aria-hidden="true">+</span></summary><div class="fix"><p>${m.means}</p><p class="do"><b>Fix:</b> ${m.fix}</p></div></details>`,
      )}
    </div>
    <h2 id="billing">Anywhere and billing</h2>
    ${billing}
    <h2 id="contact">Talk to a human</h2>
    ${contact()}
    <p><a href="/privacy">Privacy policy</a> · <a href="/terms">Terms of use (draft)</a> · <a href="/compare">How Farside compares</a></p>
  </div>
</div>`;
  return page(
    {
      path: PATH,
      title: "Support · Farside",
      description: DESC,
      script: "site",
      og: "support",
      current: "support",
      jsonLd: graph(
        webPage({ path: PATH, name: "Farside support", description: DESC, image: ogUrl(assets, "support"), breadcrumb: true }),
        breadcrumbs(PATH, crumbs),
        howTo(PATH, {
          name: "How to set up Farside",
          description: "Set up Farside to see and control your Mac from your iPhone or iPad.",
          tools: ["Mac with macOS 26 or later and Apple silicon (M1 or later)", "iPhone or iPad with iOS or iPadOS 26 or later"],
          steps: SETUP.map((s) => ({ name: s.name, text: s.text })),
        }),
        faqPage(PATH, MSG_QAS),
      ),
    },
    assets,
    body,
  );
}
