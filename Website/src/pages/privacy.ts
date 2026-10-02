// Source: Docs/launch/PRIVACY-POLICY.md §2 (draft of 28 Sep 2026), with "Farside Remote" renamed to the
// Anywhere plan used on this site. Every [TO FILL] / [CONFIRM] marker is kept in the HTML comment below.

import { config } from "../../site.config";
import { html } from "../lib/html";
import { longDate } from "./dates";
import { docBody, ownerComment, pageHero, type Section } from "./doc";
import { detail, email, ogUrl, page, type Assets } from "./layout";
import { breadcrumbs, graph, webPage } from "./schema";

const OPEN_ITEMS = [
  "Effective date: config.privacyEffective, set to the production deploy date (build:prod refuses to build without it; preview builds show the build date).",
  "Who we are: legal name and country, email contact only (owner decision 30 Sep 2026: no postal address published). Set config.contact.postalAddress to show one.",
  "[TO FILL] privacy@ address on the real domain (config.contact.privacyEmail).",
  "[TO FILL] EU/UK representative or data protection officer, only if counsel says one is required. Not rendered.",
  "Support email retention: 24 months (owner, 1 Oct 2026).",
  "[TO FILL] If serving the EU or UK: legal bases (for example contract and legitimate interests) and international transfers. Not rendered.",
  "Support email: Cloudflare Email Routing forwards to Gmail (Google), named under 'Who receives information'.",
  "No beta waitlist on the site since 1 Oct 2026 (edge/flags.ts), so the waitlist sections are gone. Bring them back (storage, IP-hash rate limit, 12-month deletion) before the waitlist is switched on again.",
  "Complaints: the Office of the Privacy Commissioner of Canada (owner, 1 Oct 2026). [TO FILL] Other routes (Quebec Law 25, EU/UK GDPR, California) only if counsel says they apply.",
  "Minimum age: 13 (owner, 1 Oct 2026).",
  "[TO FILL] Contact block: postal address.",
  "NEW, not in the draft: the website loads Google Fonts, which sends visitors' IP addresses to Google. Disclosed below; self-host the fonts to remove it.",
  "2 Oct 2026 audit against Backend/src and the apps at 20aded1: added guest viewing, files, Mac audio, Face ID, alert-action records, parental-consent stops, the random install identifier; alerts use fixed wording; purge timing is daily, so short retention periods read 'within a day'.",
];

const S: Section[] = [
  {
    id: "short",
    title: "The short version",
    body: html`<ul class="short">
  <li>Farside lets you see and control your own Mac from your iPhone or iPad. There is no Farside account, and the apps never ask for your name, email address or phone number. This website has no sign-up form.</li>
  <li>What is on your Mac’s screen, its sound if you share it, what you type, what you say and the files you send travel between your own devices, encrypted. We do not record, store or look at your screen, keystrokes, clipboard, files or voice.</li>
  <li>Our servers usually introduce your devices to each other and, if you subscribe to the Farside Anywhere plan, pass encrypted traffic along when your devices cannot connect directly. To do that they see technical details such as IP addresses, timing and data volume, and random identifiers for each paired Mac and device.</li>
  <li>We check that your subscription was signed by Apple. Apple handles your payment; we never see your card or Apple Account details.</li>
  <li>No ads. No tracking. No analytics or advertising SDKs. We do not sell your data.</li>
</ul>
<p><b>Who we are.</b> Farside is made by ${detail(config.contact.legalName, "legal name")}, ${config.contact.postalAddress ?? "in Canada"}. Privacy questions go to ${email("privacy")}.</p>`,
  },
  {
    id: "devices",
    title: "What stays on your devices",
    body: html`<ul>
  <li><b>Screen and sound.</b> After you allow Screen Recording in macOS, Farside for Mac captures the display, app or window you choose and streams it to your paired iPhone or iPad using WebRTC with DTLS-SRTP encryption. If you turn on Share Mac audio, the Mac’s sound is streamed the same way. The stream is not saved. It is not sent to us in readable form.</li>
  <li><b>Control.</b> After you enable control and allow Accessibility in macOS, taps and keys on your iPhone or iPad become pointer and keyboard actions on your Mac. They are not logged.</li>
  <li><b>Typing help.</b> When you click on your Mac, Farside for Mac can check whether the clicked item is a text field so your iPhone or iPad can open its keyboard. It checks only the type of item. It does not read what is in it.</li>
  <li><b>Voice input.</b> When you tap the microphone, your iPhone or iPad converts speech to text using Apple’s speech recognition on the device. Only the text is sent to your Mac, when you tap Done. We never receive audio. If on-device recognition is not available for your language, Farside turns voice input off; it does not send audio to a server instead.</li>
  <li><b>Camera.</b> Used only to scan the pairing code on your Mac. Pictures are not saved or sent.</li>
  <li><b>Face ID.</b> If you turn it on in Settings, Farside asks iOS to confirm it’s you before connecting to or forgetting a Mac. Face ID is handled by iOS; Farside only learns whether the check passed.</li>
  <li><b>Local network.</b> Used to connect your iPhone or iPad to your Mac when they are on the same network.</li>
  <li><b>Clipboard.</b> While you control your Mac from your iPhone or iPad, text you copy on the Mac is sent to your device automatically, encrypted, and kept on its clipboard for 5 minutes, on that device only. Text goes from your device to the Mac only when you tap Paste. Clipboard contents never reach our servers and are not logged.</li>
  <li><b>Files.</b> When you choose to send a file, photo, video, text or web link to your Mac (including from the Share menu), or a file from your Mac, it travels between your devices inside the same encrypted connection. We never receive it.</li>
  <li><b>Settings and trust.</b> Your pairing trust is stored in the Keychain on your devices and is not synced to iCloud. Preferences such as pointer speed live on the device.</li>
</ul>`,
  },
  {
    id: "connect",
    title: "What our servers see to connect you",
    body: html`<p>When you pair an iPhone or iPad with a Mac, the Mac shows a code that contains a random room identifier, a one-time token, an encryption key and an expiry of about two minutes. The key stays on your two devices. Our connection service forwards connection-setup messages between them; those messages are encrypted with that key, so we cannot read them.</p>
<p>Each time a device connects, our service receives its IP address (as any internet service does), the random room identifier, a random token and the time. It uses the IP address only while the connection is open, to limit abuse, and does not store it. It stores the connection state it needs, such as hashed tokens, connection times, the relay server list it last sent each device, and the status of relay credentials, and deletes it after 30 days without a connection, except the room identifier and a one-way hash of your pairing, which are kept until you remove the Mac’s server room, so that a device can still turn alerts off.</p>
<p>It also keeps a registry of Mac room identifiers, stored as a one-way hash, so it can limit abuse and block misuse. A Mac is added the first time it connects; there is no approval step. The registry entry is deleted when you choose Remove This Mac’s Server Room in the Settings of Farside for Mac, or after 12 months without use. Entries blocked for abuse are kept to enforce the block.</p>
<p>Our service keeps security audit records (event names, shortened identifiers and a hashed subscription identifier) for 30 days, and service logs for up to 7 days. Neither contains IP addresses or the content of your messages.</p>
<p>Our connection service runs on Cloudflare. If a direct connection is not possible and you have the Anywhere plan, your encrypted stream passes through a relay that Cloudflare also runs. Cloudflare can see IP addresses, port numbers, timing and how much data passed. It cannot decrypt the stream. Relay credentials are short-lived and tied to a random room identifier, not to you. To find network addresses, connection setup also contacts a STUN server operated by Cloudflare.</p>`,
  },
  {
    id: "notifications",
    title: "Notifications (agent alerts, beta)",
    body: html`<p>Farside only asks to send notifications if you turn on agent alerts. To deliver them, your iPhone or iPad’s Apple push notification token is sent to our server and stored with the random room identifier of the Mac it belongs to, a one-way hash of your pairing, and your alert settings (whether alerts are on, whether they may break through Focus, whether to show the agent’s name), your language, the app build, the major version of iOS or iPadOS and whether it is a test or live build.</p>
<p>When a coding agent on your Mac needs you, Farside for Mac tells our server so, with the kind of agent and a short hashed identifier for its session, which we keep briefly to avoid repeat alerts. The alert itself always uses the same fixed wording and contains no screen contents, prompts, file names or agent names. If you open, snooze, decline or dismiss an alert, the app tells our server which, and we keep that with the alert record. Alert records expire after 15 minutes and are deleted within a day.</p>
<p>Turning agent alerts off in Farside deletes the token from our server. Turning notifications off in iOS Settings only stops them from appearing; the token stays on our server until you turn agent alerts off in Farside, remove the Mac’s server room, or leave it unused for 12 months.</p>
<p>Separately, a session Live Activity uses its own push token so we can end it on your Lock Screen. We store that token with the room identifier and delete it once the session’s Live Activity has ended, and in any case within two days.</p>`,
  },
  {
    id: "subscription",
    title: "Subscription information",
    body: html`<p>The Anywhere plan is an auto-renewing subscription bought through Apple. Apple, not us, processes payment. To unlock relay access, the app sends our server the signed transaction that Apple provides, together with a random identifier the app creates for your device (it is not derived from your Apple Account or your device’s hardware). Our server checks Apple’s signature on the transaction and stores: which subscription product it is, when it was bought, when it renews or expires, its status (active, in a grace period, expired or revoked) and any refund or revocation date, Apple’s identifier for the subscription, stored only as a keyed hash of Apple’s original transaction ID, a keyed hash of Apple’s identifier for your download of the app, whether it is a live or test purchase, and which of your devices it is enabled on (up to 3), by their random identifiers, with the room identifier each last used.</p>
<p>We also receive notices from Apple about renewals, cancellations and refunds so that access matches your subscription, and keep a record of each notice for 90 days so we do not process it twice. We keep your subscription record while your subscription is active and for 90 days afterwards, then delete it.</p>
<p>If Apple tells us that a parent or guardian has withdrawn consent for a child’s purchase, we stop Anywhere for that download of the app and keep the keyed hash of its identifier, with the date, until at least 12 months have passed since the stop and the related subscription records are deleted, so the plan stays stopped.</p>`,
  },
  {
    id: "guests",
    title: "Guest viewing",
    body: html`<p>With the Anywhere plan, Farside for Mac can make a link that lets up to two people watch your shared screen in a web browser for up to ten minutes. Guests cannot control your Mac or hear its sound, and you approve each one on the Mac after checking a key with them.</p>
<p>The guest’s browser opens a page from our connection service, which receives the guest’s IP address and browser request like any website, plus random identifiers and public keys for that guest session. Setup messages between your Mac and the guest’s browser are encrypted so that we cannot read them, and the video is encrypted between your Mac and the guest’s browser, directly or through Cloudflare’s relay. We do not store the video. Guest session details are kept only while the session lasts, apart from short-lived relay credential records. A guest can record what they are shown, so share links only with people you trust.</p>`,
  },
  {
    id: "support",
    title: "Support",
    body: html`<p>If you email us we receive your email address and whatever you choose to send, and we use it to reply. We keep support emails for 24 months. Please do not send passwords or screenshots of private content.</p>`,
  },
  {
    id: "website",
    title: "This website and downloads",
    body: html`<p>This website is hosted by Cloudflare (Cloudflare Pages), which receives your IP address and the pages or files you request. The site uses no cookies, no analytics and no advertising. Your browser stores your animation preference and your best score in the footer game; neither is sent to us. The site’s fonts load from Google Fonts, so your browser also sends your IP address to Google when it fetches them.</p>
<p>When you choose Check for Updates, Farside for Mac downloads a small update file from this website. The request includes your IP address, the app’s name and version, and the version of the Sparkle update library. It does not send a system profile, and the app does not check automatically.</p>`,
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
    body: html`<p>To connect your devices; to verify your subscription and give you relay access; to run guest viewing when you use it; to deliver agent alerts you turned on; to keep the service secure and limit abuse; to answer your questions; and to meet legal obligations. We do not use it for advertising, profiling or sale.</p>`,
  },
  {
    id: "recipients",
    title: "Who receives information",
    body: html`<ul>
  <li><b>Cloudflare</b>: runs our connection service and stores its records (room identifiers, subscription records and push tokens); provides the STUN and relay servers, DNS and network services; hosts this website; and receives email sent to our getfarside.com addresses and forwards it to us.</li>
  <li><b>Apple</b>: the App Store, purchases, push notifications and App Store server notifications. Apple’s own privacy policy applies to its services.</li>
  <li><b>Google</b> (Google Fonts): fonts for this website.</li>
  <li><b>Google</b> (Gmail): the mailbox where we read and answer email sent to our getfarside.com addresses.</li>
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
    <tr><td>Room identifier and one-way hash of your pairing, on the connection service</td><td>Until you choose Remove This Mac’s Server Room, the Mac pairs a different device, or the room is blocked for abuse</td></tr>
    <tr><td>Mac room identifiers</td><td>Until you choose Remove This Mac’s Server Room on the Mac or ask us, or after 12 months without use. Identifiers blocked for abuse are kept to enforce the block.</td></tr>
    <tr><td>Push notification tokens and alert settings</td><td>Until you turn off agent alerts in Farside or remove the Mac’s server room, and at most 12 months unused</td></tr>
    <tr><td>Live Activity push tokens</td><td>Until the Live Activity ends, and at most two days</td></tr>
    <tr><td>Alert records and what you did with each alert</td><td>Expire after 15 minutes; deleted within a day</td></tr>
    <tr><td>Subscription record, including your devices’ random identifiers</td><td>The active term plus 90 days</td></tr>
    <tr><td>Apple subscription notices</td><td>90 days</td></tr>
    <tr><td>Parental-consent stops (a keyed hash and a date)</td><td>Until at least 12 months have passed and the related subscription records are deleted</td></tr>
    <tr><td>Guest viewing sessions</td><td>Only while the session lasts (relay credential records: until they expire)</td></tr>
    <tr><td>Security audit records (no IP addresses or content)</td><td>30 days</td></tr>
    <tr><td>Service logs (event names and shortened identifiers, no IP addresses or content)</td><td>Up to 7 days</td></tr>
    <tr><td>Support emails</td><td>24 months</td></tr>
    <tr><td>Data on your devices</td><td>Until you remove the pairing or delete the app</td></tr>
  </tbody>
</table>`,
  },
  {
    id: "security",
    title: "Security",
    body: html`<p>Media is encrypted between your devices with DTLS-SRTP. Connection-setup messages use AES-256-GCM with a key that never reaches our servers. Connections to our servers use TLS. Trust is kept in the Keychain. Pairing codes expire quickly and the Mac must approve each iPhone or iPad. Stop Sharing on the Mac ends access immediately.</p>
<p>No system is perfectly secure. Keep your iPhone or iPad locked and your Mac updated; anyone holding your paired, unlocked device can use what you have allowed.</p>`,
  },
  {
    id: "choices",
    title: "Your choices and rights",
    body: html`<ul>
  <li>Stop sharing at any time from the Mac menu bar. Remove a paired iPhone or iPad from Farside on your Mac. Remove a Mac from the iPhone or iPad. End a guest at any time from Farside on your Mac.</li>
  <li>To delete what our servers hold about your Mac, open Settings on the Mac and choose Remove This Mac’s Server Room under Server Data. On the iPhone or iPad, Server Data removes that device from your subscription. Neither cancels your Apple subscription, and subscription records are still kept for 90 days after access ends, as described above. Removing a device or a pairing on its own does not delete server data.</li>
  <li>You can also email ${email("privacy")}. With no account, we may ask you to prove ownership from the device.</li>
  <li>Change permissions (camera, microphone, speech recognition, Face ID, local network, notifications, screen recording, accessibility) in your device settings.</li>
  <li>Cancel your subscription in your Apple Account subscription settings. Refunds are handled by Apple.</li>
  <li>You can ask what we hold about you, ask for correction or deletion, and object to processing. Depending on where you live, you may have further rights. You can complain to the Office of the Privacy Commissioner of Canada (<a href="https://www.priv.gc.ca" rel="noopener">priv.gc.ca</a>).</li>
</ul>`,
  },
  {
    id: "children",
    title: "Children",
    body: html`<p>Farside is not directed to children under 13. We do not knowingly collect personal information from children, and there is no account.</p>`,
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
Who we are: ${detail(config.contact.legalName, "legal name")}, ${config.contact.postalAddress ?? "Canada"}.</p>`,
  },
];

/** The production deploy date (site.config.ts); a preview build shows its build date instead (build:prod requires the real one). */
function effective() {
  return config.privacyEffective ?? longDate(new Date().toISOString().slice(0, 10));
}

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
  lead: html`How Farside handles information across Farside for iPhone and iPad, Farside for Mac, our connection service and this website. The short version: <b>no account, no ads, no tracking</b>.`,
  extra: html`<p class="meta-row"><span class="cap">Last updated · <b>${config.legalUpdated}</b></span><span class="cap">Effective · <b>${effective()}</b></span></p>`,
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
