// Source: Docs/launch/PRIVACY-POLICY.md §2; clipboard, metadata, removal and purchase wording
// reconciled with main 4524689 on 5 Oct 2026; image/OCR/folder/workspace wording additionally
// reconciled with combined 84dc0a5 on 5 Oct 2026. Unpublished draft; remaining review markers stay below.

import { config } from "../../site.config";
import { html, raw } from "../lib/html";
import { docBody, ownerComment, pageHero, tbc, type Section } from "./doc";
import { detail, email, ogUrl, page, type Assets } from "./layout";
import { breadcrumbs, graph, webPage } from "./schema";

const OPEN_ITEMS = [
  "[TO FILL] Effective date (rendered as 'to be confirmed').",
  "[TO FILL] Who we are: legal entity or individual name, registered address, country (config.contact.legalName / postalAddress).",
  "[TO FILL] privacy@ address on the real domain (config.contact.privacyEmail).",
  "[TO FILL] EU/UK representative or data protection officer, only if counsel says one is required. Not rendered.",
  "[CONFIRM] Exact shipping text clipboard behavior: default-enabled negotiated Mac-to-phone text sync during an admitted control session, user-initiated phone-to-Mac Paste, and incoming text written local-only with a five-minute expiry request. Images request local-only storage without expiry; reviewed OCR copies request neither option. No user-facing sync toggle is claimed.",
  "[CONFIRM] Final archive and disclosures match explicit image transfer, temporary local OCR processing, persisted Mac folder grants, phone downloads, and saved workspace preferences; no provider or physical acceptance is inferred from this draft.",
  "[CONFIRM] Connection-service logging and retention once the production stack is final. Recommended: no request logs beyond 7 days, none containing message bodies.",
  "[CONFIRM] STUN configuration (rendered as 'may contact a STUN server operated by Cloudflare').",
  "[CONFIRM] Notifications section assumes agent alerts ship in 1.0 as a beta (PRODUCT D29). Remove the section if push does not ship.",
  "[CONFIRM] Deployed purchase storage matches the source's keyed hash of the original transaction ID; complete production service and purchase-lifecycle acceptance.",
  "[CONFIRM] Deployed cleanup matches subscription expiry/grace plus 90 days and notification deduplication after 90 days. Verify scheduler execution and provider backups/logs before publication; these are eligibility thresholds, not deletion receipts.",
  "[TO FILL] Support email retention (rendered: 24 months, to be confirmed).",
  "[TO FILL] Website hosting provider (rendered: Cloudflare Pages, to be confirmed). [CONFIRM] no cookies or analytics on the site.",
  "[CONFIRM] Sparkle update check sends only IP, app version and macOS version; system profiling off.",
  "[TO FILL] If serving the EU or UK: legal bases (for example contract and legitimate interests) and international transfers. Not rendered.",
  "[TO FILL] Other recipients: email provider, support tool (rendered: 'our email provider, to be confirmed').",
  "[CONFIRM] Cloudflare's role: relay, and network, DNS and hosting services.",
  "[CONFIRM] Persisted room/authentication and entitlement metadata, authenticated deletion, retained security blocks/revocations and cleanup jobs match the deployed service. Local Forget alone is not server deletion.",
  "[TO FILL] Server request log retention (rendered: 7 days, to be confirmed).",
  "[CONFIRM] Exact-build local trust retirement and authenticated server deletion/retry. A verified Mac removal marker retires usable trust but is not physical Keychain-row deletion. Provider retention and Apple billing remain separate.",
  "[TO FILL] Rights and complaint routes under the laws that apply (PIPEDA and Quebec Law 25, EU/UK GDPR, California). Rendered generically.",
  "[TO FILL] Minimum age for 'not directed to children' (13 or 16, per counsel; rendered: 13, to be confirmed).",
  "[TO FILL] Contact block: name, postal address, email.",
  "NEW, not in the draft: the website loads Google Fonts, which sends visitors' IP addresses to Google. Disclosed below; self-host the fonts to remove it.",
  "NAME: the plan is 'Anywhere' on the website but 'Farside Remote' in SUBSCRIPTION-SETUP.md and STORE-LISTING.md. Pick one before launch.",
];

const S: Section[] = [
  {
    id: "short",
    title: "The short version",
    body: html`<ul class="short">
  <li>Farside lets you see and control your own Mac from your iPhone. There is no Farside account. We do not ask for your name, email address or phone number.</li>
  <li>Your Mac screen, control input and accepted voice text travel between your devices, encrypted. Our connection service does not receive their readable contents. Farside does not save a stream recording; explicit local text recognition, clipboard copies and file downloads have the storage described below.</li>
  <li>Our servers introduce your devices to each other and, if you subscribe to the Anywhere plan, pass encrypted traffic along when your devices cannot connect directly. To do that they see technical details such as IP addresses, timing and data volume, and a random identifier for each paired Mac.</li>
  <li>We check your subscription with Apple. Apple handles your payment; we never see your card or Apple Account details.</li>
  <li>No ads. No tracking. No analytics or advertising SDKs. We do not sell your data.</li>
</ul>
<p><b>Who we are.</b> Farside is made by ${detail(config.contact.legalName, "legal name")}, ${detail(config.contact.postalAddress, "registered address")}. Privacy questions go to ${email("privacy")}.</p>`,
  },
  {
    id: "devices",
    title: "What stays on your devices",
    body: html`<ul>
  <li><b>Screen.</b> After you allow Screen Recording in macOS, the Farside Mac app captures the display you choose and streams it to your paired phone using WebRTC with DTLS-SRTP encryption. The stream is not saved as a recording. Text recognition can temporarily copy a displayed frame on the phone, as described below. It is not sent to us in readable form.</li>
  <li><b>Control.</b> After you enable control and allow Accessibility in macOS, taps and keys on your phone become pointer and keyboard actions on your Mac. They are not logged.</li>
  <li><b>Typing help.</b> When you click on your Mac, the Mac app can check whether the clicked item is a text field so your phone can open its keyboard. It checks only the type of item. It does not read what is in it.</li>
  <li><b>Voice input.</b> When you tap the microphone, your iPhone converts speech to text using Apple’s speech recognition on the device. Only the text is sent to your Mac, when you tap Done. We never receive audio. If on-device recognition is not available for your language, Farside turns voice input off; it does not send audio to a server instead.</li>
  <li><b>Camera.</b> Used only to scan the pairing code on your Mac. Pictures are not saved or sent.</li>
  <li><b>Local network.</b> Used to connect your phone to your Mac when they are on the same network.</li>
  <li><b>Text clipboard.</b> Text moves encrypted between your paired devices. When both devices support it, automatic Mac-to-phone text sync is enabled by default: Farside watches for changes to the Mac clipboard during an active, authorized control session. It does not send the clipboard contents already present when sync starts. Automatic sync is unavailable while the session is paused, locked, concealed, View-only or in Low Data Mode. On the phone, Farside checks clipboard metadata to offer Paste; it reads clipboard text for transfer to the Mac only when you choose the system Paste action. Farside keeps no clipboard history. Incoming Mac text replaces the phone’s system clipboard with a local-only entry and a requested five-minute expiry; text pasted into another app has that app’s retention. Text sent to the Mac can remain in its system clipboard until replaced or cleared. Concealed/transient Mac clipboard items are refused, and each text transfer is limited to 256 KB.</li>
  <li><b>Image clipboard.</b> Choose the system Paste control to send one image to the Mac, or Get Mac image to fetch its clipboard image. After current-authority and marked-private checks, the image is normalized to PNG and transferred encrypted, with limits of 8 MiB encoded and 16 million pixels. Images are not automatically synced or pasted into another app. Incoming phone images request local-only clipboard storage but no timed expiry; Mac clipboard images can remain until replaced or cleared. Copies saved or pasted elsewhere follow the receiving app's retention.</li>
  <li><b>Text from a picture.</b> When you choose Select text from picture, Farside temporarily copies the visible part of a displayed frame and recognizes text locally with Apple's Vision framework. You can edit it before choosing Copy reviewed text. No frame or recognized text is sent to a recognition server. Closing clears the tool's displayed image and text, although an in-flight recognition job keeps its working image until it finishes. Copy reviewed text uses the ordinary system clipboard without requesting local-only storage or expiry; closing does not erase that copied result.</li>
  <li><b>Shared folders and downloads.</b> Mac Settings lets you choose read-only shared folders. Bookmarks and filesystem identities persist on that Mac across restarts. During an allowed control session, your paired phone can receive folder/file names, kinds, sizes and modification times, and download chosen files over encrypted transport. The browser uses opaque entry identifiers rather than transmitting absolute Mac paths. Revoke removes the Mac grant; ending a session does not delete it. Completed downloads remain in the phone app's Documents, manageable in Files. Revocation or disconnect does not erase downloaded copies or copies saved elsewhere.</li>
  <li><b>Workspace preferences.</b> Requested workspace lists can show running app names and window titles on your paired phone. Saved task views keep your label, Mac association, display hint and viewing-position numbers in phone preferences, not a screenshot or document contents. Personalized shortcuts keep app associations, labels, ordering and key combinations. These survive ending a session; you can delete a saved view or restore an app's default shortcuts. Avoid private information in labels you do not want retained there.</li>
  <li><b>Settings and trust.</b> Your pairing trust is stored in the Keychain on your devices and is not synced to iCloud. Preferences such as pointer speed live on the device.</li>
</ul>`,
  },
  {
    id: "connect",
    title: "What our servers see to connect you",
    body: html`<p>When you pair a phone with a Mac, the Mac shows a code that contains a random room identifier, a one-time token, an encryption key and an expiry of about two minutes. The key stays on your two devices. Our connection service forwards connection-setup messages between them; those messages are encrypted with that key, so we cannot read them.</p>
<p>Each time a device connects, our service receives its IP address (as any internet service does), the random room identifier, authentication proof and connection timing. It persists room/authentication hashes, connection-policy state, entitlement associations and relay credential/revocation metadata beyond the live connection. The screen-encryption key is not sent to the service. Application cleanup rules are described below; provider logs and backups need separate retention review.</p>
<p>If a direct connection is not possible and you have the Anywhere plan, your encrypted stream passes through a relay run by our provider Cloudflare. Cloudflare can see IP addresses, port numbers, timing and how much data passed. It cannot decrypt the stream. Relay credentials are short-lived and tied to a random room identifier, not to you. To find network addresses, connection setup may also contact a STUN server operated by Cloudflare.</p>`,
  },
  {
    id: "notifications",
    title: "Notifications (agent alerts, beta)",
    body: html`<p>Farside only asks to send notifications if you turn on agent alerts. To deliver them, your phone’s Apple push notification token is sent to our server and stored with the random room identifier and pairing identity of the Mac it belongs to. Notifications say a task on your Mac needs you and contain no screen contents, prompts or file names. An alert’s opaque pairing identity keeps an explicit connection tied to its originating Mac. Turning alerts off in Farside requests authenticated removal of their registration, events and reports; removal may remain pending and retry if the service is unavailable. Turning notifications off in iOS Settings stops their presentation but does not itself confirm server deletion. Session Live Activities use separate addresses so the service can end them while the phone is suspended; agent-alert opt-out does not remove those addresses, and bounded ending retries may retain them briefly.</p>`,
  },
  {
    id: "subscription",
    title: "Subscription information",
    body: html`<p>The Anywhere plan is an auto-renewing subscription bought through Apple. Apple, not us, processes payment. To verify access, the app sends Apple’s signed transaction to our service. Our subscription record stores a keyed hash derived from Apple’s original transaction ID, the product and live/test environment, access/grace/revocation dates and device associations. We do not receive payment-card details or your Apple Account password.</p>
<p>We also receive notices from Apple about renewals, cancellations and refunds so that access matches your subscription. Subscription records and their device associations become eligible for cleanup 90 days after the verified expiry or grace-period deadline, whichever is later. Apple notification deduplication records become eligible after 90 days. Scheduled cleanup is not a promise of deletion at an exact time, and provider logs/backups require separate review. Removing a pairing or server data does not cancel Apple billing. New purchases remain disabled in current preparation builds until the intended service has passed acceptance.</p>`,
  },
  {
    id: "support",
    title: "Support",
    body: html`<p>If you email us we receive your email address and whatever you choose to send, and we use it to reply. We keep support emails for ${tbc("24 months")}. Please do not send passwords or screenshots of private content.</p>`,
  },
  {
    id: "website",
    title: "This website and downloads",
    body: html`<p>This website is hosted by ${tbc("Cloudflare (Cloudflare Pages)")}, which receives your IP address and the pages or files you request. The site uses no cookies, no analytics and no advertising. Its fonts load from Google Fonts, so your browser also sends your IP address to Google when it fetches them.</p>
<p>When the Mac app checks for updates it downloads a small update file from our server; the request includes your IP address, the app version and your macOS version. It does not send a system profile.</p>`,
  },
  {
    id: "diagnostics",
    title: "Diagnostics",
    body: html`<p>Farside contains no crash-reporting or analytics service. If you choose to share analytics with app developers in iOS or macOS settings, Apple may give us anonymous, aggregated crash and usage reports; we cannot identify you from them. A hidden diagnostic setting can save technical connection statistics (frame rate, bitrate, connection type) to a file on your device. Nothing uploads that file; you can send it to us if you choose.</p>`,
  },
  {
    id: "not-collected",
    title: "What we do not collect",
    body: html`<p>Our connection service does not receive readable screen, keystroke, clipboard, chosen file or recognized-text contents. The local processing and storage you request are described above. Farside does not collect your contacts, location, advertising identifiers, browsing history or health information for the connection service.</p>`,
  },
  {
    id: "use",
    title: "How we use information",
    body: html`<p>To connect your devices; to verify your subscription and give you relay access; to deliver agent alerts you turned on; to keep the service secure and limit abuse; to answer your questions; and to meet legal obligations. We do not use it for advertising, profiling or sale.</p>`,
  },
  {
    id: "recipients",
    title: "Who receives information",
    body: html`<ul>
  <li><b>Cloudflare</b>: the relay, network services and hosting for this website.</li>
  <li><b>Apple</b>: the App Store, purchases, push notifications and App Store server notifications. Apple’s own privacy policy applies to its services.</li>
  <li><b>Google</b>: fonts for this website only.</li>
  <li><b>Our email provider</b>, to receive and answer support email ${raw('<span class="placeholder">(provider to be confirmed)</span>')}.</li>
  <li>Professional advisers or authorities, when legally required.</li>
</ul>
<p>Each provider is bound to protect information at least as strongly as this policy states. We do not sell your information or share it for advertising.</p>`,
  },
  {
    id: "retention",
    title: "How long we keep information",
    body: html`<p>These are the current application’s cleanup rules. Eligibility is handled by scheduled cleanup; it does not certify deletion at an exact time or from provider logs/backups. Effective provider retention still needs confirmation before publication.</p>
<table class="table">
  <thead><tr><th scope="col">Information</th><th scope="col">Kept for</th></tr></thead>
  <tbody>
    <tr><td>Room/authentication and connection-policy metadata</td><td>Persisted beyond a live connection. Successful authenticated server removal clears ordinary room state and room/device links; unused active database room entries are eligible for cleanup after 365 days.</td></tr>
    <tr><td>Security blocks and pending relay revocations</td><td>May remain after removal to enforce abuse prevention and revocation.</td></tr>
    <tr><td>Agent-alert registrations</td><td>Removed after successful app opt-out or authenticated removal; pending requests retry. Stale registrations are eligible after 365 days or inactive-room cleanup.</td></tr>
    <tr><td>Subscription records and device associations</td><td>Eligible 90 days after the verified expiry/grace deadline; unlinking removes the requested device association separately.</td></tr>
    <tr><td>Apple notification deduplication</td><td>Eligible after 90 days.</td></tr>
    <tr><td>Server request logs, if any</td><td>${tbc("7 days")}</td></tr>
    <tr><td>Support emails</td><td>${tbc("24 months")}</td></tr>
    <tr><td>Data on your devices</td><td>Local trust retirement, folder grants, downloads, workspace preferences and system clipboard entries have separate lifetimes. Only incoming Mac text requests a five-minute clipboard expiry; images and reviewed OCR copies do not. Ending a session or removing a pairing does not clear every saved file, folder grant or copy in another app. Delete saved views, restore shortcut defaults, revoke folders and manage downloaded files using their respective controls.</td></tr>
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
  <li>Stop sharing at any time from the Mac menu bar. Local Remove Phone retires that Mac’s usable pairing trust after local cleanup is confirmed; it does not by itself confirm server deletion. If macOS refuses deletion because of Keychain ownership, Farside can replace and verify the saved pairing with a removal marker; the Keychain row may remain without usable pairing credentials.</li>
  <li>The phone’s unlink and Mac Server Data controls request authenticated server removal and expose pending cleanup and retry. Required proof is kept while removal is pending. Successful removal does not erase retained security/purchase records or certify provider erasure. You can also email ${email("privacy")}; with no account, we may ask you to prove ownership from the device.</li>
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

const DESC = "How Farside handles information: no account, no ads, no tracking. Your screen, control input and chosen content travel between your own devices, encrypted.";

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
