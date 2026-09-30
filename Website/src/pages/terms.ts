// Draft terms of use. There is no terms document in Docs/launch yet (STORE-LISTING.md allows Apple's standard
// EULA or custom terms), so this is a plain-language starting point for counsel, clearly marked as a draft.

import { config } from "../../site.config";
import { html } from "../lib/html";
import { docBody, ownerComment, pageHero, type Section } from "./doc";
import { detail, email, ogUrl, page, type Assets } from "./layout";
import { breadcrumbs, graph, webPage } from "./schema";

const P = config.pricing;

const OPEN_ITEMS = [
  "DRAFT: counsel must review everything on this page before launch. Remove the draft banner only after sign-off.",
  "[TO FILL] Contracting party: postal address (config.contact.postalAddress). The legal name is set.",
  "[TO FILL] Governing law and courts (config.contact.governingLaw).",
  "[DECIDE] Minimum age. None is set here; a minimum above the App Store age rating forces an age-rating override (PRIVACY-POLICY.md section 5).",
  "[DECIDE] Use Apple's standard Licensed Application EULA for the iOS app (assumed here) or a custom EULA with Apple's required clauses.",
  "[CONFIRM] Counsel review of the liability cap: the greater of what you paid us in the 12 months before the claim, or CA$50. Payments go through Apple, so check that 'paid us' reads correctly.",
];

const S: Section[] = [
  {
    id: "agreement",
    title: "Who these terms are between",
    body: html`<p>These terms are between you and ${detail(config.contact.legalName, "legal name")} (“we”, “us”). They cover the Farside iPhone and iPad app, the Farside Mac helper, our connection and relay service, and this website. By using any of them, you agree to these terms.</p>`,
  },
  {
    id: "what",
    title: "What Farside is",
    body: html`<p>Farside lets you see and control your own Mac from your iPhone or iPad. It is free when your devices are on the same local network. The optional Farside Anywhere plan adds access over the internet.</p>`,
  },
  {
    id: "your-mac",
    title: "Your Mac, your responsibility",
    body: html`<ul>
  <li>Use Farside only with Macs you own or are allowed to control.</li>
  <li>You are responsible for what happens on your Mac while it is shared, including anything done by someone holding your paired, unlocked phone.</li>
  <li>Keep your phone locked, and keep your Mac and both apps up to date. Stop Sharing in the Mac menu bar ends a session immediately.</li>
</ul>`,
  },
  {
    id: "apple",
    title: "The app, Apple and these terms",
    body: html`<p>The iPhone and iPad app is licensed to you under Apple’s standard Licensed Application End User License Agreement, and these terms add to it. Apple is not responsible for the app or these terms. The Mac helper is a free download from this website; you may install and use it with Farside, but please don’t sell it, modify and redistribute it, or use it to build a competing service.</p>`,
  },
  {
    id: "anywhere",
    title: "The Anywhere plan",
    body: html`<ul>
  <li>Anywhere is an auto-renewing subscription sold inside the app through Apple, monthly or yearly. New subscribers get a ${P.trialDays}-day free trial.</li>
  <li>The price is shown before you subscribe. Payment is charged to your Apple Account when you confirm the purchase, and the subscription renews unless you cancel at least 24 hours before the end of the current period.</li>
  <li>Manage or cancel any time in Settings › your name › Subscriptions. Refunds are handled by Apple under its policies.</li>
  <li>One subscription works on up to 3 of your devices.</li>
  <li>Relaying encrypted traffic costs us real money. We don’t advertise unlimited use; if we ever introduce a usage limit, we will tell you in the app before it applies.</li>
</ul>`,
  },
  {
    id: "beta",
    title: "Beta features",
    body: html`<p>Some features are labelled beta, including agent alerts. Beta features may change, break or be withdrawn, and are provided without any promise that they will keep working.</p>`,
  },
  {
    id: "acceptable-use",
    title: "Acceptable use",
    body: html`<p>Don’t use Farside to access a computer without permission, to break the law, or to harm other people. Don’t try to get around the subscription, overload or probe our service, or interfere with other people’s use of it.</p>`,
  },
  {
    id: "privacy",
    title: "Privacy",
    body: html`<p>The <a href="/privacy">privacy policy</a> explains what we collect and why. In short: no account, no ads, no tracking, and we never see your screen.</p>`,
  },
  {
    id: "open-source",
    title: "Open-source software",
    body: html`<p>Farside includes open-source software, including WebRTC under the BSD 3-Clause licence. The licence notices are in the app’s Legal screen.</p>`,
  },
  {
    id: "availability",
    title: "Availability and changes",
    body: html`<p>We work hard to keep Farside running, but we can’t promise it will always be available or free of errors. Even on your own network, our connection service introduces your devices to each other, so an outage can affect free use too. We may change or discontinue features; we’ll give notice of significant changes in the app or on this website.</p>`,
  },
  {
    id: "disclaimers",
    title: "Disclaimers and liability",
    body: html`<p>To the extent the law allows, Farside is provided “as is”, and we are not liable for indirect or consequential losses, lost data or lost profits. Where liability can’t be excluded, our total liability is limited to the greater of the amounts you paid us in the 12 months before the claim, or CA$50. Nothing in these terms limits rights you have under consumer protection laws that can’t be waived.</p>`,
  },
  {
    id: "ending",
    title: "Ending these terms",
    body: html`<p>You can stop using Farside at any time: unpair your devices, delete the apps and cancel any subscription. We may suspend access if you break these terms, or when needed to protect the service or other people.</p>`,
  },
  {
    id: "law",
    title: "Governing law",
    body: html`<p>These terms are governed by the laws of ${detail(config.contact.governingLaw, "the governing jurisdiction")}.</p>`,
  },
  {
    id: "changes",
    title: "Changes to these terms",
    body: html`<p>We may update these terms. We’ll post the new version here and, for significant changes, tell you in the app before they apply.</p>`,
  },
  {
    id: "contact",
    title: "Contact",
    body: html`<p>Questions about these terms: ${email("support")}.</p>`,
  },
];

const DESC = "Draft terms of use for Farside: using it with your own Mac, the Anywhere subscription, beta features and the plain-language rules. Not yet in effect.";

export function termsPage(assets: Assets) {
  const crumbs: [string, string][] = [
    ["Home", "/"],
    ["Terms of use (draft)", "/terms"],
  ];
  const body = html`${ownerComment("Owner checklist for /terms. Resolve each item, then delete this comment:", OPEN_ITEMS)}
${pageHero({
  crumbs,
  cap: "Terms of use · draft",
  title: html`The fine <em>print</em>`,
  lead: html`The rules for using Farside, in plain language. This page is a <b>draft</b> that hasn’t been through legal review yet.`,
  extra: html`<div class="draft" role="note"><p class="cap">Draft · not in effect</p><p>These terms are a working draft for review. They will take effect when Farside launches, and the final version may differ. Until then, nothing on this page is an agreement.</p></div>`,
})}
${docBody(S)}`;
  return page(
    {
      path: "/terms",
      title: "Terms of use (draft) · Farside",
      description: DESC,
      script: "site",
      current: "terms",
      jsonLd: graph(
        webPage({ path: "/terms", name: "Farside terms of use (draft)", description: DESC, image: ogUrl(assets), breadcrumb: true }),
        breadcrumbs("/terms", crumbs),
      ),
    },
    assets,
    body,
  );
}
