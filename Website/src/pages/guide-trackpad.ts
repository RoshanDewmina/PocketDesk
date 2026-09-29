// Guide targeting "trackpad for mac", "mac trackpad", "remote trackpad" (Docs/launch/ASO-STRATEGY.md §2.3).

import { config } from "../../site.config";
import { html } from "../lib/html";
import { ctaBand, faqList, figure, gestureTable, guideHero } from "./guide";
import { guideCards, ogUrl, page, type Assets } from "./layout";
import { breadcrumbs, faqPage, graph, howTo, webPage, type QA } from "./schema";

const PATH = "/iphone-as-mac-trackpad";
const TITLE = "Use your iPhone as a trackpad for your Mac · Farside";
const DESC =
  "Turn your iPhone into a trackpad for your Mac: slide to move, tap to click, two fingers to scroll, with click haptics, a pointer you can see and zoom that follows you.";
const R = config.requirements;

const QAS: QA[] = [
  {
    q: "Can I use my iPhone as a trackpad for my Mac?",
    a: html`<p>Yes. With Farside, the whole iPhone screen works like a trackpad: slide one finger to move your Mac’s pointer, tap to click, and use two fingers to scroll. You also see your Mac’s screen on the phone, so you don’t have to look back at the desk.</p>`,
  },
  {
    q: "Does it connect over Bluetooth?",
    a: html`<p>No. Farside connects over your network: free when your iPhone and Mac share one, or over the internet with the Anywhere plan. It isn’t a Bluetooth mouse, so there’s nothing to pair in Bluetooth settings.</p>`,
  },
  {
    q: "Can I right-click and drag?",
    a: html`<p>Yes. Tap with two fingers to right-click. To drag, double-tap and hold, then slide; lift to drop.</p>`,
  },
  {
    q: "Does it support Force Touch or pressure?",
    a: html`<p>No. A phone screen can’t send pressure to a Mac. Use a right-click (two-finger tap) or the app’s own buttons instead.</p>`,
  },
  {
    q: "Can I turn off the click haptics?",
    a: html`<p>Yes. Click haptics are on by default and can be switched off in the app’s settings.</p>`,
  },
];

export function trackpadGuidePage(assets: Assets) {
  const crumbs: [string, string][] = [
    ["Home", "/"],
    ["Use your iPhone as a Mac trackpad", PATH],
  ];
  const body = html`${guideHero({
    crumbs,
    cap: "Guide · iPhone as a Mac trackpad",
    title: html`Use your iPhone as a Mac <em>trackpad.</em>`,
    lead: html`Farside turns the whole iPhone screen into a trackpad for your Mac. Slide to move the pointer, tap to click, two fingers to scroll. You feel every click, and the pointer is big enough to find.`,
    meta: "About 3 minutes to read",
  })}
<div class="w guide">
  <div class="prose">
    <h2 id="why">Why a trackpad, not a touchscreen</h2>
    <p>On a phone, your Mac’s buttons are tiny. Tapping them directly means your finger covers the very thing you’re aiming at. Farside works like the trackpad on a MacBook instead: your finger moves the pointer, and a tap clicks wherever the pointer is. You can hit small targets, and your thumb never hides what you’re clicking.</p>
    ${figure(assets, "phone-coach", "The practice pad: the pointer is already on the button, so a tap anywhere clicks it.")}

    <h2 id="gestures">Every gesture</h2>
    <p>These work anywhere on the screen, in portrait or landscape.</p>
    ${gestureTable()}

    <h2 id="haptics">Clicks you can feel</h2>
    <p>Every click your Mac accepts plays a haptic tap on your iPhone. You know it landed without squinting at the screen, which matters most when the thing you clicked is tiny.</p>

    <h2 id="pointer">A pointer you can find</h2>
    <p>The pointer is drawn by your phone, sharp at any zoom, in the same shape your Mac is using: the arrow, the text I-beam or the pointing hand. Pick <b>Small</b>, <b>Medium</b>, <b>Large</b> or <b>Extra Large</b>.</p>
    ${figure(assets, "phone-live", "A big, sharp pointer over your real desktop.")}

    <h2 id="zoom">Zoom that follows you</h2>
    <p>Pinch to zoom in on small text. As you move, the view follows the pointer, so you’re never hunting for where you left it. Switch between <b>Fit</b>, which shows the whole screen, and <b>Fill</b>, which uses every pixel of the phone, from the controls.</p>

    <h2 id="keys">Keyboard, voice and shortcuts</h2>
    <p>Swipe up on the handle for <b>Keys</b>: a keyboard with ⌘ ⌥ ⌃ ⇧, Tab, Esc and the arrows. Or tap <b>Mic</b> and talk; speech is recognized on your iPhone and the words land on your Mac. A three-finger swipe opens Mission Control or switches Spaces, the same as on a Mac trackpad.</p>

    <h2 id="tips">Tips</h2>
    <ul>
      <li>Pinch in before precise work; the pointer stays sharp at any zoom.</li>
      <li>Use two fingers to scroll long documents, up and down or sideways.</li>
      <li>Double-tap the handle to type without opening the controls.</li>
      <li>Left-handed or holding the phone in one hand? The trackpad works anywhere on the glass.</li>
    </ul>

    <h2 id="start">Get started</h2>
    <p>You need a Mac on ${R.mac} with the free Farside helper, and an iPhone on ${R.iphone} (or an iPad on ${R.ipad}). The <a href="/control-mac-from-iphone">setup guide</a> walks through it: install the helper, allow two permissions, scan a code, tap Connect.</p>

    <h2 id="faq">Questions</h2>
    ${faqList(QAS)}

    <h2 id="more">Keep reading</h2>
    ${guideCards(PATH)}
  </div>
</div>
${ctaBand()}`;

  const image = ogUrl(assets, "iphone-as-mac-trackpad");
  return page(
    {
      path: PATH,
      title: TITLE,
      ogTitle: "Your iPhone is a Mac trackpad · Farside",
      description: DESC,
      script: "site",
      og: "iphone-as-mac-trackpad",
      current: "guides",
      jsonLd: graph(
        webPage({ path: PATH, name: "Use your iPhone as a Mac trackpad", description: DESC, image, breadcrumb: true }),
        breadcrumbs(PATH, crumbs),
        howTo(PATH, {
          name: "How to use your iPhone as a trackpad for your Mac",
          description: DESC,
          tools: ["Mac with macOS 26 or later", "iPhone with iOS 26 or later", "Farside helper for Mac", "Farside app for iPhone"],
          steps: [
            { name: "Set up Farside", text: "Install the free Farside helper on your Mac, allow Screen Recording and Accessibility, and pair your iPhone by scanning the QR code." },
            { name: "Connect", text: "Tap Connect in the Farside app. The whole iPhone screen becomes a trackpad for your Mac." },
            { name: "Move and click", text: "Slide one finger to move the pointer and tap anywhere to click where the pointer is." },
            { name: "Scroll, right-click and drag", text: "Drag with two fingers to scroll, tap with two fingers to right-click, and double-tap and hold to drag." },
          ],
        }),
        faqPage(PATH, QAS),
      ),
    },
    assets,
    body,
  );
}
