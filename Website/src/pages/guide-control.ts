// Guide targeting "control mac from iphone" / "control mac" (Docs/launch/ASO-STRATEGY.md §2.3 open long tail).

import { config } from "../../site.config";
import { html, type Html } from "../lib/html";
import { ctaBand, faqList, figure, gestureTable, guideHero, steps } from "./guide";
import { guideCards, ogUrl, page, type Assets } from "./layout";
import { breadcrumbs, faqPage, graph, howTo, webPage, type QA } from "./schema";

const PATH = "/control-mac-from-iphone";
const TITLE = "How to control your Mac from your iPhone · Farside";
const DESC =
  "Control your Mac from your iPhone in a few steps: install the free Mac helper, allow two permissions, scan a QR code, tap Connect. No account; free on your own network.";
const R = config.requirements;
const P = config.pricing;

const STEP_DATA: { title: string; text: string; body: Html; img?: string; caption?: string }[] = [
  {
    title: "Install the Farside helper on your Mac",
    text: "Download the free Farside helper for Mac, open it and move it to Applications if it asks. It lives in the menu bar.",
    body: html`<p>Download the free Farside helper for Mac from this website <span class="placeholder">(coming soon)</span>, open it, and move it to Applications if it asks. It lives quietly in the menu bar. It’s signed with an Apple Developer ID and notarized by Apple.</p>`,
  },
  {
    title: "Allow Screen Recording and Accessibility",
    text: "Screen Recording lets your iPhone see the Mac's screen; Accessibility lets taps become clicks and typing become typing. The setup window notices each switch by itself.",
    body: html`<p><b>Screen Recording</b> lets your iPhone see the screen. <b>Accessibility</b> lets taps become clicks and typing become typing. Farside opens the right page in System Settings and its setup window notices each switch by itself. macOS may ask you to quit and reopen Farside once.</p>`,
    img: "mac-setup",
    caption: "Two permissions, then it stops asking.",
  },
  {
    title: "Install Farside on your iPhone",
    text: "Get the Farside app for iPhone or iPad from the App Store.",
    body: html`<p>Get Farside from the App Store <span class="placeholder">(coming soon)</span>. It runs on ${R.iphone} and on iPad with ${R.ipad}.</p>`,
  },
  {
    title: "Pair with a QR code",
    text: "On the Mac, choose Pair a Phone in the Farside menu. In the app, tap Scan and point the camera at the code, then choose Allow on the Mac.",
    body: html`<p>On the Mac, choose <b>Pair a Phone…</b> in the Farside menu. In the app, tap <b>Scan</b> and point the camera at the code, then choose <b>Allow</b> on the Mac. That’s the pairing: no account, no password. The code expires after about two minutes, so nobody can reuse it later.</p>`,
  },
  {
    title: "Allow Local Network on your iPhone",
    text: "When iOS asks to find devices on your local network, choose Allow so your iPhone can find your Mac at home.",
    body: html`<p>iOS asks once whether Farside may find devices on your local network. Choose <b>Allow</b>; that’s how your iPhone finds your Mac at home.</p>`,
  },
  {
    title: "Tap Connect",
    text: "Tap Connect. Your Mac's screen appears and the whole iPhone screen becomes a trackpad. The first time, a short practice pad shows you how to steer.",
    body: html`<p>Tap <b>Connect</b>. Your Mac appears, sharp and full screen, and the whole iPhone screen becomes a trackpad. The first time, a short practice pad shows you how to steer; nothing you do there reaches the Mac.</p>`,
    img: "phone-home",
    caption: "One Mac, one honest status line, one big Connect.",
  },
];

const QAS: QA[] = [
  {
    q: "Can I control my Mac from my iPhone for free?",
    a: html`<p>Yes, when your iPhone and your Mac are on the same local network. Farside is free there, with no account and no ads. Reaching your Mac over the internet needs the Anywhere plan (${P.final ? "" : "planned at "}${P.monthly} a month or ${P.yearly} a year, with a ${P.trialDays}-day free trial).</p>`,
  },
  {
    q: "Do my iPhone and Mac need to be on the same Wi-Fi?",
    a: html`<p>For free use, yes: both need to be on the same local network. With the Anywhere plan, your iPhone can reach your Mac over the internet instead, for example on cellular, without port forwarding or a VPN.</p>`,
  },
  {
    q: "Does it work if my Mac is asleep or locked?",
    a: html`<p>No. Your Mac needs to be awake and logged in. While your iPhone is connected, Farside keeps the Mac awake; if the Mac locks, sleeps or restarts, sharing stops and your iPhone tells you why. Turning on <b>Wake for network access</b> on the Mac helps it nap less.</p>`,
  },
  {
    q: "Can I use an iPad instead of an iPhone?",
    a: html`<p>Yes. The same app runs on iPad with ${R.ipad}, and the bigger glass makes an even bigger trackpad.</p>`,
  },
  {
    q: "Is it safe to control my Mac from my phone?",
    a: html`<p>Your screen, keystrokes and voice travel between your own devices, encrypted end to end. You approve every phone on the Mac, and <b>Stop Sharing</b> in the menu bar ends a session immediately. Keep your phone locked: anyone holding your paired, unlocked phone can use what you’ve allowed. Details are in the <a href="/privacy">privacy policy</a>.</p>`,
  },
];

export function controlGuidePage(assets: Assets) {
  const crumbs: [string, string][] = [
    ["Home", "/"],
    ["Control your Mac from your iPhone", PATH],
  ];
  const body = html`${guideHero({
    crumbs,
    cap: "Guide · Control your Mac from your iPhone",
    title: html`Control your Mac from your iPhone.`,
    lead: html`Farside shows your Mac’s real screen on your iPhone and turns the glass into a trackpad. Setup is a few steps and no account. Here’s the whole thing, start to finish.`,
    meta: "About 4 minutes to read",
  })}
<div class="w guide">
  <div class="prose">
    <h2 id="need">What you need</h2>
    <ul>
      <li>${R.mac}, with the free Farside helper.</li>
      <li>An iPhone on ${R.iphone}, or an iPad on ${R.ipad}, with the Farside app.</li>
      <li>Both on the same network for free use. To reach your Mac over the internet, the Anywhere plan.</li>
    </ul>
    <p class="callout"><b>Farside is in beta.</b> The requirements above are planned, and the apps are coming soon. <a href="/#beta">Join the beta</a> to try it first.</p>

    <h2 id="steps">Step by step</h2>
    ${steps(STEP_DATA.map((s) => ({ title: s.title, body: s.body, figure: s.img ? figure(assets, s.img, s.caption ?? "") : undefined })))}

    <h2 id="steer">Steer it like a trackpad</h2>
    <p>Your finger doesn’t go to the button. The pointer is already on it, and a tap anywhere clicks right there, with a small haptic tap so you feel it land. There’s more on this in <a href="/iphone-as-mac-trackpad">using your iPhone as a Mac trackpad</a>.</p>
    ${gestureTable()}
    ${figure(assets, "phone-live", "Your Mac, crisp and full screen, with a big pointer and an ember dot where you clicked.")}

    <h2 id="type">Type, talk and copy</h2>
    <p>Swipe up on the handle for the controls. <b>Keys</b> opens a keyboard with ⌘ ⌥ ⌃ ⇧, Tab, Esc and the arrows. <b>Mic</b> turns speech into text: tap it, say it, tap Done, and the words land on your Mac. Speech is recognized on your iPhone and the audio never leaves it. <b>Clip</b> copies text from your Mac to your phone, or pastes from your phone to your Mac, only when you ask.</p>
    ${figure(assets, "phone-dock", "Keys, Mic, Clip, Fit and Mode, one swipe up.")}

    <h2 id="away">When you’re away from home</h2>
    <p>At home Farside connects your devices directly over your own network, for free. Away from home, the <a href="/#pricing">Anywhere plan</a> lets your iPhone reach your Mac over the internet, through an encrypted relay when a direct connection isn’t possible. There’s nothing to set up on your router. Your Mac still needs to be awake; see <a href="/remote-desktop-for-mac">remote desktop for Mac</a> for how the connection works.</p>

    <h2 id="control">You stay in control</h2>
    <p>Every phone is approved on the Mac, and the menu-bar panel shows when a phone is connected. <b>Stop Sharing</b> ends it immediately; turn off <b>Allow control</b> and the phone can look but not touch.</p>
    ${figure(assets, "mac-menu", "Quiet in the menu bar; Stop Sharing is always one click away.")}

    <h2 id="faq">Questions</h2>
    ${faqList(QAS)}

    <h2 id="more">Keep reading</h2>
    ${guideCards(PATH)}
  </div>
</div>
${ctaBand()}`;

  const image = ogUrl(assets, "control-mac-from-iphone");
  return page(
    {
      path: PATH,
      title: TITLE,
      ogTitle: "Control your Mac from your iPhone · Farside",
      description: DESC,
      script: "site",
      og: "control-mac-from-iphone",
      current: "guides",
      jsonLd: graph(
        webPage({ path: PATH, name: "Control your Mac from your iPhone", description: DESC, image, breadcrumb: true }),
        breadcrumbs(PATH, crumbs),
        howTo(PATH, {
          name: "How to control your Mac from your iPhone with Farside",
          description: DESC,
          tools: ["Mac with macOS 26 or later", "iPhone with iOS 26 or later", "Farside helper for Mac", "Farside app for iPhone"],
          steps: STEP_DATA.map((s) => ({ name: s.title, text: s.text, image: s.img ? assets.img[s.img]?.src : undefined })),
        }),
        faqPage(PATH, QAS),
      ),
    },
    assets,
    body,
  );
}
