// Guide targeting "remote desktop mac", "remote mac", "mac remote" (Docs/launch/ASO-STRATEGY.md §2.3).
// Honest about limits: no Windows/Android, no audio, the Mac must be awake; Anywhere is planned.

import { config } from "../../site.config";
import { html } from "../lib/html";
import { ctaBand, faqList, figure, guideHero } from "./guide";
import { guideCards, ogUrl, page, type Assets } from "./layout";
import { breadcrumbs, faqPage, graph, howTo, webPage, type QA } from "./schema";

const PATH = "/remote-desktop-for-mac";
const TITLE = "Remote desktop for Mac on iPhone and iPad · Farside";
const DESC =
  "A remote desktop app for your own Mac: see its real screen on your iPhone or iPad and control it. Free on your network; the Anywhere plan adds internet access.";
const R = config.requirements;
const P = config.pricing;

const QAS: QA[] = [
  {
    q: "Is Farside a VNC app?",
    a: html`<p>No. Farside doesn’t use VNC. It streams your Mac’s screen as encrypted video over WebRTC and sends your taps and keys back over the same encrypted connection. It works only with its own Mac helper.</p>`,
  },
  {
    q: "Can I use remote desktop on my Mac without port forwarding?",
    a: html`<p>Yes. At home Farside finds your Mac on your own network. With the Anywhere plan it connects over the internet through an encrypted relay when a direct connection isn’t possible, so there’s no port forwarding, router setup or VPN.</p>`,
  },
  {
    q: "Is remote desktop for Mac safe?",
    a: html`<p>With Farside, you approve every phone on the Mac, pairing codes expire after about two minutes, and the picture, keystrokes and voice are encrypted end to end between your devices. The relay can’t decrypt what passes through it. <b>Stop Sharing</b> in the Mac’s menu bar ends a session immediately.</p>`,
  },
  {
    q: "Does Farside stream sound?",
    a: html`<p>No. Farside streams your Mac’s picture, not its audio.</p>`,
  },
  {
    q: "Can I reach my Mac when I’m away from home?",
    a: html`<p>That’s what the Anywhere plan is for: your iPhone reaches your Mac over the internet, for example on cellular or a café’s Wi-Fi. It’s planned at ${P.monthly} a month or ${P.yearly} a year, with a ${P.trialDays}-day free trial, bought in the app through Apple. Your Mac needs to be awake and logged in.</p>`,
  },
];

export function remoteGuidePage(assets: Assets) {
  const crumbs: [string, string][] = [
    ["Home", "/"],
    ["Remote desktop for Mac", PATH],
  ];
  const body = html`${guideHero({
    crumbs,
    cap: "Guide · Remote desktop for Mac",
    title: html`Remote desktop for your Mac.`,
    lead: html`A remote desktop app shows a computer’s screen on another device and lets you control it. Farside does that for one thing only: your own Mac, from your iPhone or iPad.`,
    meta: "About 4 minutes to read",
  })}
<div class="w guide">
  <div class="prose">
    <h2 id="what">What Farside is, and isn’t</h2>
    <p><b>It is</b> your real macOS desktop, with all your apps and files, on your iPhone or iPad. The phone becomes a trackpad, keyboard and microphone for the Mac.</p>
    <p><b>It isn’t</b> for Windows or Android, for reaching someone else’s computer, or a second display for your Mac. It streams the picture, not sound.</p>

    <h2 id="home">At home: free</h2>
    <p>When your iPhone or iPad and your Mac share a network, Farside connects them directly, for free, with no account. Pair once by scanning a code on the Mac and approving the phone there; after that it’s one tap.</p>
    ${figure(assets, "phone-home", "Your Mac waits on the Home screen; Connect closes the gap.")}

    <h2 id="away">Away from home: the Anywhere plan</h2>
    <p>The Anywhere plan lets your iPhone reach your Mac over the internet: on cellular, at a friend’s place, on a hotel’s Wi-Fi. When your devices can’t connect directly, an encrypted relay passes the stream along; it can’t read what it carries. There’s no port forwarding, router setup or VPN.</p>
    <p>Anywhere is planned at ${P.monthly} a month or ${P.yearly} a year, after a ${P.trialDays}-day free trial, and is sold only inside the app through Apple. Prices are in Canadian dollars; the App Store shows yours before you subscribe.</p>

    <h2 id="how">How the connection works</h2>
    <ol>
      <li><b>Pairing puts a key on both devices.</b> The QR code on your Mac carries a one-time token and an encryption key that expire in about two minutes. You approve the phone on the Mac.</li>
      <li><b>Our connection service introduces the devices.</b> The setup messages are encrypted with that key, so the service can’t read them.</li>
      <li><b>The Mac streams its screen to your phone</b> as encrypted video (WebRTC with DTLS-SRTP). Your taps and keys go back the same way.</li>
      <li><b>You end it from either side.</b> End session on the phone, or Stop Sharing in the Mac’s menu bar.</li>
    </ol>
    ${figure(assets, "mac-menu", "The Mac always shows who is connected, with Stop Sharing one click away.")}

    <h2 id="setup">Set it up</h2>
    <p>You need a Mac on ${R.mac} and an iPhone on ${R.iphone} or an iPad on ${R.ipad}. Install the free Farside helper on the Mac, allow Screen Recording and Accessibility, scan the pairing code with the Farside app, and tap Connect. The <a href="/control-mac-from-iphone">step-by-step guide</a> has the details.</p>

    <h2 id="limits">Good to know</h2>
    <ul>
      <li>Your Mac needs to be awake and logged in. Farside keeps it awake while you’re connected, but it can’t wake a sleeping Mac or log in after a restart.</li>
      <li>Farside shows one Mac display at a time.</li>
      <li>Pressure gestures like Force Touch aren’t possible from a phone screen; right-click works instead.</li>
      <li>Free use needs both devices on the same local network, and Farside’s connection service to introduce them.</li>
    </ul>
    ${figure(assets, "phone-nap", "When something’s wrong, Farside says what happened and the one thing to do.")}

    <h2 id="faq">Questions</h2>
    ${faqList(QAS)}

    <h2 id="more">Keep reading</h2>
    ${guideCards(PATH)}
  </div>
</div>
${ctaBand()}`;

  const image = ogUrl(assets, "remote-desktop-for-mac");
  return page(
    {
      path: PATH,
      title: TITLE,
      ogTitle: "Remote desktop for your Mac · Farside",
      description: DESC,
      script: "site",
      og: "remote-desktop-for-mac",
      current: "guides",
      jsonLd: graph(
        webPage({ path: PATH, name: "Remote desktop for Mac", description: DESC, image, breadcrumb: true }),
        breadcrumbs(PATH, crumbs),
        howTo(PATH, {
          name: "How to set up remote desktop for your Mac on iPhone or iPad",
          description: DESC,
          tools: ["Mac with macOS 26 or later", "iPhone or iPad with iOS or iPadOS 26 or later", "Farside helper for Mac", "Farside app"],
          steps: [
            { name: "Install the Mac helper", text: "Install the free Farside helper on your Mac. It lives in the menu bar." },
            { name: "Allow two permissions", text: "Allow Screen Recording and Accessibility so the phone can see and control the Mac." },
            { name: "Pair", text: "Scan the QR code on your Mac with the Farside app and approve the phone on the Mac." },
            { name: "Connect", text: "Tap Connect. At home it's free; away from home, the Anywhere plan connects over the internet." },
          ],
        }),
        faqPage(PATH, QAS),
      ),
    },
    assets,
    body,
  );
}
