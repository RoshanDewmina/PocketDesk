// Comparison page. Facts come only from Docs/BENCHMARK-WORKBENCH-2026-09-28.md and
// Docs/COMPETITOR-LANDSCAPE-2026-09-28.md (both checked 28 Sep 2026), which cite the vendor pages linked below.
// Rules: no performance claims, no disparagement, vendor claims marked, Farside's unreleased features marked
// planned, "Not listed" when our sources say nothing. Competitor prices are left out on purpose: the two
// source documents disagree with each other and with SUBSCRIPTION-SETUP.md, so each vendor's own page wins.

import { config } from "../../site.config";
import { html, type Html } from "../lib/html";
import { ctaBand, faqList, guideHero } from "./guide";
import { guideCards, ogUrl, page, type Assets } from "./layout";
import { breadcrumbs, faqPage, graph, webPage, type QA } from "./schema";

const PATH = "/compare";
const AS_OF = "28 September 2026";
const TITLE = "Farside vs Workbench, Jump Desktop, Screens and more";
const DESC =
  "How Farside compares with Astropad Workbench, Jump Desktop, Screens 5 and Remote Mac Desktop Control, feature by feature, from public information as of 28 September 2026.";
const P = config.pricing;

const COLS = ["Farside", "Astropad Workbench", "Jump Desktop", "Screens 5", "Remote Mac Desktop Control"] as const;

type Row = { label: string; cells: [Html | string, Html | string, Html | string, Html | string, Html | string] };

const planned = (s: string) => html`${s} <span class="tag">Planned</span>`;
const beta = (s: string) => html`${s} <span class="tag">Beta</span>`;
const vendor = (s: string) => html`${s} <span class="tag">Vendor claim</span>`;
const NL = html`<span class="nl">Not listed</span>`;

const ROWS: Row[] = [
  {
    label: "Release status",
    cells: [
      html`In beta, not yet released`,
      "Version 1.3.1, 17 September 2026",
      "Jump Desktop 10, 24 August 2026",
      "Updated 15 September 2026",
      "Available on the App Store",
    ],
  },
  {
    label: "Account needed",
    cells: ["No", "Yes: email, Apple or Google sign-in, with two-factor authentication", NL, NL, "No"],
  },
  {
    label: "Pairing",
    cells: [
      "Scan a QR code, approve the phone on the Mac",
      "Sign in to your account",
      "Jump Desktop Connect, for relay-based pairing",
      NL,
      "QR code with certificate pinning",
    ],
  },
  {
    label: "Touch on iPhone",
    cells: [
      beta("Relative trackpad with click haptics"),
      "Direct touch: tap where you want",
      "Trackpad-style, with a customizable shortcut toolbar",
      NL,
      "Trackpad-first: tap, scroll and drag gestures",
    ],
  },
  { label: "Voice dictation", cells: [beta("Yes, recognized on the iPhone"), "Yes", NL, NL, NL] },
  { label: "Clipboard", cells: [beta("Both ways, when you ask"), "Clipboard sync", NL, NL, NL] },
  { label: "Apple Pencil", cells: ["No", "Yes, including Scribble", NL, NL, NL] },
  {
    label: "Mac displays",
    cells: [
      "One at a time",
      "Unified Display combines all Mac displays",
      vendor("Up to six 4K host displays with Fluid 2.0"),
      NL,
      NL,
    ],
  },
  {
    label: "Over the internet",
    cells: [
      planned("Anywhere plan, through an encrypted relay"),
      "Global relay, no port forwarding",
      "Through the Jump Desktop Connect subscription",
      "Built in since June 2026",
      html`<span class="nl">Not confirmed</span>`,
    ],
  },
  {
    label: "Free use",
    cells: [
      "Unlimited on your own network",
      "Free tier of 20 to 30 minutes a day",
      "Paid app (one-time purchase)",
      NL,
      "Free, with in-app purchases",
    ],
  },
  {
    label: "Paid plans",
    cells: [
      planned(`Anywhere: ${P.monthly} a month or ${P.yearly} a year, ${P.trialDays}-day free trial`),
      "Monthly or yearly subscription",
      "One-time app purchase, plus a per-computer Connect subscription for relay access",
      "Subscription or lifetime purchase",
      "In-app purchases",
    ],
  },
  {
    label: "Streaming",
    cells: [
      beta("Encrypted WebRTC video"),
      vendor("LIQUID codec, “perceptually lossless”"),
      vendor("Fluid 2.0 with HEVC and 4:4:4 colour"),
      "VNC-based",
      "Live screen mirror",
    ],
  },
  {
    label: "Requirements",
    cells: [planned("macOS 26, iOS or iPadOS 26"), "macOS 15, iOS or iPadOS 26", NL, NL, NL],
  },
  {
    label: "AI agent features",
    cells: [planned("“Agent needs you” alerts, as a beta"), "Positioned for AI agent workflows", NL, NL, NL],
  },
];

const QAS: QA[] = [
  {
    q: "Does Farside need an account?",
    a: html`<p>No. You pair by scanning a QR code on your Mac and approving the phone there.</p>`,
  },
  {
    q: "Is Farside free?",
    a: html`<p>Yes, without a time limit, when your iPhone or iPad and your Mac are on the same network. The Anywhere plan (planned at ${P.monthly} a month or ${P.yearly} a year, ${P.trialDays}-day free trial) adds access over the internet.</p>`,
  },
  {
    q: "Does Farside support Apple Pencil or direct touch?",
    a: html`<p>Not today. Farside is built around a relative trackpad: your finger moves the pointer and a tap clicks where it is. If you need Apple Pencil, Astropad Workbench lists support for it, including Scribble.</p>`,
  },
  {
    q: "Where do these facts come from?",
    a: html`<p>From each product’s public pages, release notes and App Store listing, checked on ${AS_OF} and linked below. Features and prices change often, so check each vendor for the current details. “Vendor claim” marks a vendor’s own description that we haven’t tested.</p>`,
  },
];

const SOURCES: [string, string][] = [
  ["Astropad Workbench product page", "https://astropad.com/product/workbench/"],
  ["Astropad Workbench on the App Store", "https://apps.apple.com/us/app/astropad-workbench/id6758788573"],
  ["Astropad Workbench help centre", "https://support.astropad.com/en/collections/18710933-workbench"],
  ["Workbench 1.3 (9to5Mac, 19 Aug 2026)", "https://9to5mac.com/2026/08/19/astropad-workbench-1-3-adds-faster-streaming-privacy-curtain-and-more/"],
  ["Jump Desktop changelog", "https://changelog.jumpdesktop.com/"],
  ["Jump Desktop Fluid 2.0 notes", "https://changelog.jumpdesktop.com/jump-desktop-with-fluid-2.0-1yMoBG"],
  ["Screens 5 release notes (Edovia)", "https://help.edovia.com/en/screens-5/faq/release-notes"],
  ["Screens (Edovia)", "https://edovia.com/en/screens"],
  ["Screens 5 pricing (Edovia)", "https://help.edovia.com/en/screens-5/faq/s5-pricing"],
  ["Remote Mac Desktop Control on the App Store", "https://apps.apple.com/us/app/remote-mac-desktop-control/id6790186904"],
];

function table(): Html {
  return html`<div class="cmp-wrap">
<table class="cmp" role="table">
  <caption class="sr-only">Farside compared with Astropad Workbench, Jump Desktop, Screens 5 and Remote Mac Desktop Control, as of ${AS_OF}</caption>
  <thead role="rowgroup"><tr role="row"><th role="columnheader" scope="col"><span class="sr-only">Feature</span></th>${COLS.map(
    (c) => html`<th role="columnheader" scope="col">${c}</th>`,
  )}</tr></thead>
  <tbody role="rowgroup">${ROWS.map(
    (r) =>
      html`<tr role="row"><th role="rowheader" scope="row">${r.label}</th>${r.cells.map(
        (c, i) => html`<td role="cell" data-label="${COLS[i]}">${c}</td>`,
      )}</tr>`,
  )}</tbody>
</table>
</div>`;
}

export function comparePage(assets: Assets) {
  const crumbs: [string, string][] = [
    ["Home", "/"],
    ["Compare", PATH],
  ];
  const body = html`${guideHero({
    crumbs,
    cap: `Compare · as of ${AS_OF}`,
    title: html`Farside, compared.`,
    lead: html`How Farside lines up against other ways to use a Mac from an iPhone or iPad, from each product’s public information. Farside isn’t released yet, so its column describes what’s in the beta and what’s planned.`,
    meta: "Facts checked 28 September 2026",
  })}
<div class="w guide wide">
  <div class="prose">
    <h2 id="table">Side by side</h2>
    <p class="callout">“Not listed” means we didn’t find it in the sources below; the feature may still exist. <span class="tag">Vendor claim</span> marks a vendor’s own description that we haven’t tested. <span class="tag">Planned</span> and <span class="tag">Beta</span> mark Farside features that aren’t released yet. We don’t compare speed: none of these apps, Farside included, has independent latency measurements that we could find.</p>
  </div>
  ${table()}
  <div class="prose">
    <h2 id="different">Where Farside is different</h2>
    <ul>
      <li><b>A trackpad, not a touchscreen.</b> Your finger moves the pointer and a tap clicks where it is, with a haptic tap on every click.</li>
      <li><b>No account.</b> A QR code and a yes on the Mac is the whole pairing.</li>
      <li><b>Free on your own network,</b> with no daily time limit. You pay only to reach your Mac over the internet.</li>
      <li><b>Agent alerts</b> (planned, as a beta) tell you when a coding agent on your Mac needs you, without putting its prompt in the notification.</li>
    </ul>

    <h2 id="not-yet">What Farside doesn’t do (yet)</h2>
    <ul>
      <li>Apple Pencil and a direct-touch mode.</li>
      <li>Several Mac displays at once, or a virtual display for a Mac without a screen.</li>
      <li>Sound: it streams the picture only.</li>
      <li>Windows, Linux or Android computers.</li>
      <li>Reaching your Mac over the internet today: that arrives with the Anywhere plan.</li>
    </ul>

    <h2 id="apple">What about Apple’s own tools?</h2>
    <p>As of ${AS_OF}, Apple’s built-in options point in other directions: Screen Sharing connects a Mac to another Mac, Sidecar makes an iPad a second display for your Mac, and iPhone Mirroring lets a Mac control an iPhone.</p>

    <h2 id="faq">Questions</h2>
    ${faqList(QAS)}

    <h2 id="sources">Sources</h2>
    <p>Checked ${AS_OF}. Product names are trademarks of their owners; this page isn’t affiliated with or endorsed by any of them. Spotted something out of date? Tell us through the <a href="/support#contact">support page</a> and we’ll correct it.</p>
    <ul class="sources">${SOURCES.map(([t, href]) => html`<li><a href="${href}" rel="noopener">${t}</a></li>`)}</ul>

    <h2 id="more">Keep reading</h2>
    ${guideCards(PATH)}
  </div>
</div>
${ctaBand()}`;

  const image = ogUrl(assets, "compare");
  return page(
    {
      path: PATH,
      title: TITLE,
      ogTitle: "Farside, compared · as of 28 September 2026",
      description: DESC,
      script: "site",
      og: "compare",
      current: "compare",
      jsonLd: graph(
        webPage({ path: PATH, name: "Farside compared", description: DESC, image, breadcrumb: true }),
        breadcrumbs(PATH, crumbs),
        faqPage(PATH, QAS),
      ),
    },
    assets,
    body,
  );
}
