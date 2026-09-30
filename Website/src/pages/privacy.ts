// Source: Docs/launch/PRIVACY-POLICY.md §2 (draft of 28 Sep 2026), with "Farside Remote" renamed to the
// Anywhere plan used on this site. Every [TO FILL] / [CONFIRM] marker is kept in the HTML comment below.

import { config } from "../../site.config";
import { html, raw } from "../lib/html";
import { docBody, ownerComment, pageHero, tbc, type Section } from "./doc";
import { detail, email, ogUrl, page, type Assets } from "./layout";
import { breadcrumbs, graph, webPage } from "./schema";

const OPEN_ITEMS = [
  "[TO FILL] Effective date (rendered as 'to be confirmed').",
  "[TO FILL] Who we are: postal address and country (config.contact.postalAddress). The legal name is set.",
  "[TO FILL] privacy@ address on the real domain (config.contact.privacyEmail).",
  "[TO FILL] EU/UK representative or data protection officer, only if counsel says one is required. Not rendered.",
  "[TO FILL] Support email retention (rendered: 24 months, to be confirmed).",
  "[TO FILL] If serving the EU or UK: legal bases (for example contract and legitimate interests) and international transfers. Not rendered.",
  "[TO FILL] Waitlist and support email provider. No email-sending code exists yet, so the page says only that we send invites. Name the provider under 'Who receives information' once chosen.",
  "[DECIDE] 12-month waitlist deletion. Nothing deletes waitlist rows automatically; the promise depends on the dated manual DELETE in Docs/launch/LAUNCH-CHECKLIST.md (task 8.5). Keep that task, or move the waitlist to a Worker with a cron.",
  "[CONFIRM] RATE_SALT is set in Cloudflare Pages production. Without it the IP hash falls back to a public salt and 'we cannot turn the hash back' stops being true.",
  "[TO FILL] Rights and complaint routes under the laws that apply (PIPEDA and Quebec Law 25, EU/UK GDPR, California). Rendered generically.",
  "[TO FILL] Minimum age for 'not directed to children' (13 or 16, per counsel; rendered: 13, to be confirmed).",
  "[TO FILL] Contact block: postal address.",
  "NEW, not in the draft: the website loads Google Fonts, which sends visitors' IP addresses to Google. Disclosed below; self-host the fonts to remove it.",
];

const S: Section[] = [
  {
    id: "short",
    title: "The short version",
    body: html`<ul class="short">
  <li>Farside lets you see and control your own Mac from your iPhone or iPad. There is no Farside account, and the apps never ask for your name, email address or phone number. If you join the beta waitlist on this website, we keep the email address you give us (see <a href="#waitlist">Beta waitlist</a>).</li>
  <li>What is on your Mac’s screen, what you type and what you say travel between your own devices, encrypted. We do not record, store or look at your screen, keystrokes, clipboard or voice.</li>
  <li>Our servers introduce your devices to each other and, if you subscribe to the Farside Anywhere plan, pass encrypted traffic along when your devices cannot connect directly. To do that they see technical details such as IP addresses, timing and data volume, and a random identifier for each paired Mac.</li>
  <li>We check your subscription with Apple. Apple handles your payment; we never see your card or Apple Account details.</li>
  <li>No ads. No tracking. No analytics or advertising SDKs. We do not sell your data.</li>
</ul>
<p><b>Who we are.</b> Farside is made by ${detail(config.contact.legalName, "legal name")}, ${detail(config.contact.postalAddress, "postal address")}. Privacy questions go to ${email("privacy")}.</p>`,
  },
  {
    id: "devices",
    title: "What stays on your devices",
    body: html`<ul>
  <li><b>Screen.</b> After you allow Screen Recording in macOS, the Farside Mac app captures the display you choose and streams it to your paired phone using WebRTC with DTLS-SRTP encryption. The stream is not saved. It is not sent to us in readable form.</li>
  <li><b>Control.</b> After you enable control and allow Accessibility in macOS, taps and keys on your phone become pointer and keyboard actions on your Mac. They are not logged.</li>
  <li><b>Typing help.</b> When you click on your Mac, the Mac app can check whether the clicked item is a text field so your phone can open its keyboard. It checks only the type of item. It does not read what is in it.</li>
  <li><b>Voice input.</b> When you tap the microphone, your iPhone converts speech to text using Apple’s speech recognition on the device. Only the text is sent to your Mac, when you tap Done. We never receive audio. If on-device recognition is not available for your language, Farside turns voice input off; it does not send audio to a server instead.</li>
  <li><b>Camera.</b> Used only to scan the pairing code on your Mac. Pictures are not saved or sent.</li>
  <li><b>Local network.</b> Used to connect your phone to your Mac when they are on the same network.</li>
  <li><b>Clipboard.</b> When you choose to copy from your Mac or paste to it, Farside moves only that text, directly between your devices and encrypted. It is not stored or logged, and Farside does not read your clipboard in the background.</li>
  <li><b>Settings and trust.</b> Your pairing trust is stored in the Keychain on your devices and is not synced to iCloud. Preferences such as pointer speed live on the device.</li>
</ul>`,
  },
  {
    id: "connect",
    title: "What our servers see to connect you",
    body: html`<p>When you pair a phone with a Mac, the Mac shows a code that contains a random room identifier, a one-time token, an encryption key and an expiry of about two minutes. The key stays on your two devices. Our connection service forwards connection-setup messages between them; those messages are encrypted with that key, so we cannot read them.</p>
<p>Each time a device connects, our service receives its IP address (as any internet service does), the random room identifier, a random token and the time. It stores the connection state it needs, such as hashed tokens, connection times and the status of relay credentials, and deletes it after 30 days without a connection.</p>
<p>It also keeps a registry of Mac room identifiers, stored as a one-way hash, so it can limit abuse and block misuse. A Mac is added the first time it connects; there is no approval step. The registry entry is deleted when you choose Remove This Mac’s Server Room in the Mac app’s Settings, or after 12 months without use. Entries blocked for abuse are kept to enforce the block.</p>
<p>Our service keeps security audit records (event names, shortened identifiers and a hashed subscription identifier) for 30 days, and service logs for up to 7 days. Neither contains IP addresses or the content of your messages.</p>
<p>Our connection service runs on Cloudflare. If a direct connection is not possible and you have the Anywhere plan, your encrypted stream passes through a relay that Cloudflare also runs. Cloudflare can see IP addresses, port numbers, timing and how much data passed. It cannot decrypt the stream. Relay credentials are short-lived and tied to a random room identifier, not to you. To find network addresses, connection setup also contacts a STUN server operated by Cloudflare.</p>`,
  },
  {
    id: "notifications",
    title: "Notifications (agent alerts, beta)",
    body: html`<p>Farside only asks to send notifications if you turn on agent alerts. To deliver them, your phone’s Apple push notification token is sent to our server and stored with the random room identifier of the Mac it belongs to, a one-way hash of your pairing, and your alert settings (whether alerts are on, whether they may break through Focus, whether to show the agent’s name), your language, the app build, your iOS version and whether it is a test or live build. To avoid repeat alerts we also keep a short record of each alert, which expires after 15 minutes.</p>
<p>Alerts say which agent needs you and contain no screen contents, prompts or file names.</p>
<p>Turning agent alerts off in Farside deletes the token from our server. Turning notifications off in iOS Settings only stops them from appearing; the token stays on our server until you turn agent alerts off in Farside, remove the Mac’s server room, or leave it unused for 12 months.</p>
<p>Separately, a session Live Activity uses its own push token so we can end it on your Lock Screen. We store that token with the room identifier and delete it within 24 hours.</p>`,
  },
  {
    id: "subscription",
    title: "Subscription information",
    body: html`<p>The Anywhere plan is an auto-renewing subscription bought through Apple. Apple, not us, processes payment. To unlock relay access, the app sends the signed transaction that Apple provides to our server. Our server verifies it with Apple and stores: which subscription product it is, when it renews or expires, Apple’s identifier for the subscription, stored only as a keyed hash of Apple’s original transaction ID, whether it is a live or test purchase, and which of your devices it is enabled on (up to 3).</p>
<p>We also receive notices from Apple about renewals, cancellations and refunds so that access matches your subscription, and keep a record of each notice for 90 days so we do not process it twice. We keep your subscription record while your subscription is active and for 90 days afterwards, then delete it.</p>`,
  },
  {
    id: "support",
    title: "Support",
    body: html`<p>If you email us we receive your email address and whatever you choose to send, and we use it to reply. We keep support emails for ${tbc("24 months")}. Please do not send passwords or screenshots of private content.</p>`,
  },
  {
    id: "waitlist",
    title: "Beta waitlist",
    body: html`<p>If you join the beta waitlist on this website, we store your email address, the page you signed up from, the version of the sign-up wording you agreed to and the time you signed up. We use them only to send you the beta invite and news about the launch.</p>
<p>We also store a random code that lets you unsubscribe. The invite and launch news are sent by us.</p>
<p>We keep your sign-up until 12 months after Farside launches, then delete it. Every email we send has an unsubscribe link. If you unsubscribe, we stop emailing you and keep only your address and the date you unsubscribed, so that we don’t contact you again, until that same deletion date.</p>
<p>To stop abuse of the sign-up form, we also keep a salted one-way hash of your IP address. It is usually deleted within an hour, and at the latest the next time anyone signs up after that hour. We cannot turn the hash back into your IP address. The waitlist is stored with Cloudflare (Cloudflare D1).</p>`,
  },
  {
    id: "website",
    title: "This website and downloads",
    body: html`<p>This website is hosted by Cloudflare (Cloudflare Pages), which receives your IP address and the pages or files you request. The site uses no cookies, no analytics and no advertising. Your browser stores your animation preference and, for one visit, the page you pressed Join from; neither is sent to us, except the page name with a waitlist sign-up. The site’s fonts load from Google Fonts, so your browser also sends your IP address to Google when it fetches them.</p>
<p>When you choose Check for Updates, the Mac app downloads a small update file from this website. The request includes your IP address, the app’s name and version, and the version of the Sparkle update library. It does not send a system profile, and the app does not check automatically.</p>`,
  },
  {
    id: "diagnostics",
    title: "Diagnostics",
    body: html`<p>Farside contains no crash-reporting or analytics service. If you choose to share analytics with app developers in iOS or macOS settings, Apple may give us anonymous, aggregated crash and usage reports; we cannot identify you from them. A hidden diagnostic setting can save technical connection statistics (frame rate, bitrate, connection type) to a file on your device. Nothing uploads that file; you can send it to us if you choose.</p>`,
  },
  {
    id: "not-collected",
    title: "What we do not collect",
    body: html`<p>The contents of your screen, keystrokes, clipboard, voice or audio recordings, contacts, photos, location, advertising identifiers, browsing history, or health information.</p>`,
  },
  {
    id: "use",
    title: "How we use information",
    body: html`<p>To connect your devices; to verify your subscription and give you relay access; to deliver agent alerts you turned on; to send the beta invite and launch news to people on the waitlist; to keep the service secure and limit abuse; to answer your questions; and to meet legal obligations. We do not use it for advertising, profiling or sale.</p>`,
  },
  {
    id: "recipients",
    title: "Who receives information",
    body: html`<ul>
  <li><b>Cloudflare</b>: runs our connection service and stores its records (room identifiers, subscription records and push tokens); provides the STUN and relay servers, DNS and network services; hosts this website; and stores the beta waitlist (Cloudflare D1).</li>
  <li><b>Apple</b>: the App Store, purchases, push notifications and App Store server notifications. Apple’s own privacy policy applies to its services.</li>
  <li><b>Google</b>: fonts for this website only.</li>
  <li><b>Our email provider</b>, to receive and answer support email and to send waitlist emails.</li>
  <li>Professional advisers or authorities, when legally required.</li>
</ul>
<p>Each provider is bound to protect information at least as strongly as this policy states. We do not sell your information or share it for advertising.</p>`,
  },
  {
    id: "retention",
    title: "How long we keep information",
    body: html`<table class="table">
  <thead><tr><th scope="col">Information</th><th scope="col">Kept for</th></tr></thead>
  <tbody>
    <tr><td>Connection state (hashed tokens, connection times, relay-credential status)</td><td>Deleted after 30 days without a connection</td></tr>
    <tr><td>Mac room identifiers</td><td>Until you choose Remove This Mac’s Server Room on the Mac or ask us, or after 12 months without use. Identifiers blocked for abuse are kept to enforce the block.</td></tr>
    <tr><td>Push notification tokens and alert settings</td><td>Until you turn off agent alerts in Farside or remove the Mac’s server room, and at most 12 months unused</td></tr>
    <tr><td>Live Activity push tokens</td><td>At most 24 hours</td></tr>
    <tr><td>Alert records used to avoid repeats</td><td>15 minutes</td></tr>
    <tr><td>Subscription record</td><td>The active term plus 90 days</td></tr>
    <tr><td>Apple subscription notices</td><td>90 days</td></tr>
    <tr><td>Security audit records (no IP addresses or content)</td><td>30 days</td></tr>
    <tr><td>Service logs (event names and shortened identifiers, no IP addresses or content)</td><td>Up to 7 days</td></tr>
    <tr><td>Support emails</td><td>${tbc("24 months")}</td></tr>
    <tr><td>Beta waitlist email address and sign-up details</td><td>Until 12 months after launch. If you unsubscribe, only your address and the unsubscribe date are kept until then.</td></tr>
    <tr><td>Hashed IP address used to limit sign-up abuse</td><td>Usually one hour; at the latest until the next sign-up after that</td></tr>
    <tr><td>Data on your devices</td><td>Until you remove the pairing or delete the app</td></tr>
  </tbody>
</table>`,
  },
  {
    id: "security",
    title: "Security",
    body: html`<p>Media is encrypted between your devices with DTLS-SRTP. Connection-setup messages use AES-256-GCM with a key that never reaches our servers. Connections to our servers use TLS. Trust is kept in the Keychain. Pairing codes expire quickly and the Mac must approve each phone. Stop Sharing on the Mac ends access immediately.</p>
<p>No system is perfectly secure. Keep your phone locked and your Mac updated; anyone holding your paired, unlocked phone can use what you have allowed.</p>`,
  },
  {
    id: "choices",
    title: "Your choices and rights",
    body: html`<ul>
  <li>Stop sharing at any time from the Mac menu bar. Remove a paired phone from Farside on your Mac. Remove a Mac from the phone.</li>
  <li>To delete what our servers hold about your Mac, open Settings on the Mac and choose Remove This Mac’s Server Room under Server Data. On the phone, Server Data removes that device from your subscription. Neither cancels your Apple subscription, and subscription records are still kept for 90 days after access ends, as described above. Removing a phone or a pairing on its own does not delete server data.</li>
  <li>You can also email ${email("privacy")}. With no account, we may ask you to prove ownership from the device.</li>
  <li>Change permissions (camera, microphone, speech, local network, notifications, screen recording, accessibility) in your device settings.</li>
  <li>Cancel your subscription in your Apple Account subscription settings. Refunds are handled by Apple.</li>
  <li>You can ask what we hold about you, ask for correction or deletion, and object to processing. Depending on where you live, you may have further rights and can complain to your privacy regulator ${raw('<span class="placeholder">(details to be confirmed)</span>')}.</li>
</ul>`,
  },
  {
    id: "children",
    title: "Children",
    body: html`<p>Farside is not directed to children under ${tbc("13")}. We do not knowingly collect personal information from children, and there is no account.</p>`,
  },
  {
    id: "changes",
    title: "Changes",
    body: html`<p>We will post changes here and, for significant changes, tell you in the app. The date at the top shows the current version.</p>`,
  },
  {
    id: "contact",
    title: "Contact",
    body: html`<p>Privacy questions: ${email("privacy")}.<br>
Who we are: ${detail(config.contact.legalName, "legal name")}, ${detail(config.contact.postalAddress, "postal address")}.</p>`,
  },
];

const DESC = "How Farside handles information: no account, no ads, no tracking. Your screen, keystrokes and voice travel between your own devices, encrypted.";

export function privacyPage(assets: Assets) {
  const crumbs: [string, string][] = [
    ["Home", "/"],
    ["Privacy policy", "/privacy"],
  ];
  const body = html`${ownerComment("Owner checklist for /privacy (from Docs/launch/PRIVACY-POLICY.md). Resolve each item, then delete this comment:", OPEN_ITEMS)}
${pageHero({
  crumbs,
  cap: "Privacy policy",
  title: html`Your screen is <em>yours.</em>`,
  lead: html`How Farside handles information across the iPhone and iPad app, the Mac helper, our connection service and this website. The short version: <b>no account, no ads, no tracking</b>, and we never see your screen.`,
  extra: html`<p class="meta-row"><span class="cap">Last updated · <b>${config.legalUpdated}</b></span><span class="cap">Effective · <b>to be confirmed</b></span></p>`,
})}
${docBody(S)}`;
  return page(
    {
      path: "/privacy",
      title: "Privacy policy · Farside",
      description: DESC,
      script: "site",
      current: "privacy",
      jsonLd: graph(
        webPage({ path: "/privacy", name: "Farside privacy policy", description: DESC, image: ogUrl(assets), breadcrumb: true }),
        breadcrumbs("/privacy", crumbs),
      ),
    },
    assets,
    body,
  );
}
