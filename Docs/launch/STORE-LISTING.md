# Farside: App Store listing package

Prepared 28 September 2026. The product is now called **Farside** (renamed from PocketDesk on 28 Sep 2026). Bundle IDs stay `com.roshan.PocketDesk.*`; code identifiers still say PocketDesk until engineering renames them. Copy is written to Apple's tone (short, benefit-first, "it just works") and fits Apple's current field limits. Nothing was registered, reserved or submitted; the name, domain and trademark checks below are read-only lookups.

**Division of labour:** `ASO-STRATEGY.md` (separate workstream) is authoritative for the title and subtitle wording, the keyword field, categories, screenshot order and messaging, and rating prompts. Values in this file are working defaults and the technical specifications (sizes, limits, compliance wording); where the two disagree, ASO-STRATEGY.md wins on positioning and this file wins on Apple's rules.

Labels: **[V]** verified today from a primary source or registry; **[R]** verified in the repo; **[I]** inference; **[O]** owner action; **[E]** engineering. Bracketed uppercase tokens such as [SHORT URL] are placeholders.

## 1. Name: Farside

### What I checked (28 Sep 2026)

| Check | Result [V] |
|---|---|
| App Store search, US and CA storefronts, iPhone, iPad and Mac (iTunes Search API), terms "farside" and "far side" | The exact name is taken. **"Farside"** by Tim Lange, Games, a space sandbox MMO released 15 Sep 2026 (id 6811149252). **"FarSide"** by Randolph W Duerr, Entertainment, released 2016 (id 1090466613). Also "Farside (5fedd3)" (Melissa Bower, Social Networking) and "Undecember: The Farside" (LINE Games). A suffixed title is therefore required. |
| Trademark: THE FAR SIDE | **US Reg. 6255846, "THE FAR SIDE", Class 41 entertainment services (website with non-downloadable cartoons), owner FarWorks, Inc., Seattle. LIVE: Sections 8 and 15 accepted 4 May 2026** (USPTO TSDR). Search results also list older FarWorks marks for cartoon prints, books, greeting cards and calendars (e.g. serial 78488052, "registered and renewed"); I did not verify those on TSDR. A web search found no FARSIDE mark in software classes 9 or 42; other FARSIDE marks seen are for clothing (FARSIDE BRAND, serial 99528209) and an abandoned food mark. A web search is not a clearance search. [V for 6255846; I for the rest] |
| Domains (registry WHOIS and DNS) | farside.com registered since 1998 (Network Solutions, expires 2028-01-25); farside.app live DNS; farside.dev live DNS; farside.io registered 8 Sep 2025 (GoDaddy); farside.co registered 2019; farside.ca registered 2015. **No match at the registry today: getfarside.com, tryfarside.com, usefarside.com, farsideapp.com.** Availability can change; I registered nothing. |
| Exact-name conflicts on the web | Not searched beyond the above. Do a proper search. |

### Reading

- The store title must carry a suffix. Working default **"Farside: Mac Remote" (19 characters)**; alternatives "Farside: Remote Mac" (19), "Farside: Remote for Mac" (23), "Farside Remote Desktop" (22). The title limit is 30 characters, and the subtitle should not repeat the suffix words. [V]
- The main legal question is **THE FAR SIDE**. The goods are far apart (cartoon entertainment versus remote-access software), which helps, but Farside is phonetically identical to a famous, actively maintained mark, and Apple's process lets a trademark owner file a claim against an app name, which can lead to removal. [V for the Apple claim process, per the App Store Connect add-a-new-app FAQ; I for enforcement likelihood]
- Mitigations: get a written trademark opinion (Canada and US) before creating the app record; always spell it as one word; never "Far Side" or "The Far Side" in copy, keywords or URLs; no cartoon, cow, or comic imagery in the icon or screenshots; keep a fallback name ready.
- Register **getfarside.com** as the primary web domain (and tryfarside.com defensively) after the trademark opinion, not before. `.ca` is owned by someone else.

### Why not PocketDesk (record for the decision log)

The old name collided with two live "Pocket Desk" products (pocketdesk.app, pocketdesk.net), a GitHub organization, and a US registration (POCKETDESK, Reg. 5228423) that was cancelled on 5 Jan 2024. Farside removes those conflicts and adds the one above.

## 2. Listing content (English, US and Canada): working defaults

| Field | Limit [V] | Working default |
|---|---|---|
| App name (store title) | 30 | Farside: Mac Remote (19) |
| Subtitle | 30 | Use your Mac from your phone (28). Alternatives: See and control your Mac (24) · Your Mac, from your phone (25) |
| Promotional text | 170 | See and control your Mac from your iPhone or iPad. Free on your Wi-Fi; add Farside Remote to reach it from anywhere. No account, nothing to set up. (147) |
| Keywords | 100 bytes | **See ASO-STRATEGY.md** (do not repeat words already in the title and subtitle; no competitor names; describe the app accurately) |
| Primary and secondary category | | **See ASO-STRATEGY.md.** Default: Utilities, then Productivity. Workbench lists Utilities and Business, Jump Business and Utilities, Screens Utilities and Productivity. [V] |
| Age rating | | 4+ (answers in PRIVACY-POLICY.md section 5) |
| Copyright | | 2026 [OWNER OR ENTITY NAME] (App Store Connect adds the symbol) |
| Support URL | required | https://[DOMAIN]/support. It must lead to real contact information: legal address, email and phone, per App Store Connect. [V] |
| Marketing URL | optional | https://[DOMAIN]/ |
| Privacy Policy URL | required | https://[DOMAIN]/privacy |
| Terms of Use (EULA) | required for subscriptions in practice | Custom Terms page, or Apple's standard EULA (https://www.apple.com/legal/internet-services/itunes/dev/stdeula/, responds today [V]). If your Terms set a minimum age above the calculated rating you must override the age rating. |
| What's New (1.0) | 4000 | Welcome to Farside. See and control your Mac from your iPhone or iPad, free on your network. Add Farside Remote to reach it from anywhere. (138) |
| In-app purchase display names | 35 | Farside Remote - Monthly (24) · Farside Remote - Yearly (23) |
| In-app purchase description | 55 | Reach your Mac from anywhere. (29) |
| Version release | | Manual, or "no earlier than" 17 Nov 2026 |

### Description working default (2357 characters; limit 4000)

```
Your Mac, from your phone.

Farside shows your Mac's screen on your iPhone or iPad and lets you use it with a touch. Check a build, finish a document, restart a script or answer a prompt without walking back to your desk.

IT JUST WORKS
Install the free Farside companion on your Mac, scan the code it shows, and approve your phone. That's it. No account. No sign-up. No router settings.

A TRACKPAD IN YOUR HAND
Slide a finger to move the pointer, tap to click, drag with two fingers to scroll. Pinch to zoom in and the view follows your pointer. You feel every click.
Type on the iPhone keyboard, or tap the microphone and speak. Your words appear on your Mac. Speech is recognized on your iPhone.

PRIVATE BY DESIGN
Your screen goes straight to your phone, encrypted. You approve every phone on your Mac, and you can stop sharing with one click. Farside does not record your screen, your keystrokes or your voice. No ads. No trackers.

FREE ON YOUR NETWORK
At home or in the office, Farside is free, with no time limit.

REACH YOUR MAC FROM ANYWHERE
Farside Remote is an optional auto-renewing subscription. It connects your phone to your Mac over cellular or any Wi-Fi, with no VPN and no port forwarding. Try it free for 7 days. The price and terms are shown before you subscribe.

WHAT'S INSIDE
- Free, unlimited use on your local network
- Farside Remote: optional subscription for use from anywhere
- Click, right-click, double-click, drag and scroll
- Pinch to zoom, fit or fill your Mac's screen
- Full keyboard with Command, Option, Control and Shift
- Voice dictation
- Portrait and landscape, iPhone and iPad
- No account required

REQUIREMENTS
iPhone with iOS 26 or later, or iPad with iPadOS 26 or later. A Mac with macOS 26 or later running the free Farside companion (download: [SHORT URL]). Screen Recording and Accessibility access are needed on the Mac. Using Farside away from your network requires the Farside Remote subscription.

SUBSCRIPTION TERMS
Farside Remote renews automatically each month or year unless canceled at least 24 hours before the end of the current period. Payment is charged to your Apple Account at confirmation of purchase. Manage or cancel anytime in Settings > your name > Subscriptions. Any unused part of a free trial is forfeited when you subscribe.

Terms of Use: [TERMS URL]
Privacy Policy: [PRIVACY URL]
```

Copy rules applied: no prices in the name, subtitle or screenshots (Guideline 2.3.7); remote access clearly marked as a subscription (2.3.2); no competitor or AI-vendor names; no unverifiable superlatives; only shipped features (2.3.1). The price is shown by the App Store and the paywall, so it is not hard-coded in the description. [V guidelines]

### Claim checklist: only publish what is true in the submitted build

| Claim in copy | Repo status (28 Sep) | Must be true by |
|---|---|---|
| Free, unlimited on the local network, "no time limit" | Local use works, but the service ends signaling rooms at 30 minutes (`ROOM_LIFETIME_SECONDS=1800`, `Server/.env.*.example`) [R] | Engineering lifts the cap; otherwise delete "no time limit" |
| No account | True [R] | n/a |
| Scan a code and approve on the Mac | Built; physical enrollment journey not yet accepted (PRODUCT section 12) | Device acceptance |
| Trackpad control, zoom, follows your pointer, click haptics | Built and installed; physical feel not accepted | Device acceptance |
| Voice dictation, recognized on the iPhone | Built (build 20260928.9), physical recognition unverified [R] | Device test in each launch language |
| Full keyboard with modifiers | Built [R] | Device test |
| iPad support | Basic adaptive layout only (PRODUCT section 2) | iPad screenshots must show real iPad UI |
| Remote from anywhere, no VPN, no port forwarding | **Not deployed**: relay and signaling not public, no StoreKit [R] | Cellular and forced-relay acceptance on two networks |
| Stop sharing with one click | Built (menu bar) [R] | Verify |
| macOS 26 and iOS 26 minimums | Deployment targets in `project.yml` [R] | Confirm final targets |

## 3. Screenshot specification and working shot list

Sizes [V, Apple specification page today]: 1 to 10 screenshots per device size, JPEG or PNG, no alpha or transparency.

| Set | Required? | Size (portrait) | Also accepted |
|---|---|---|---|
| iPhone 6.9" | Primary set | 1320 x 2868 | 1290 x 2796; 1260 x 2736 (landscape swaps width and height) |
| iPhone 6.5" | Required only if 6.9" is not provided | 1284 x 2778 | 1242 x 2688 |
| iPad 13" | Required because the app runs on iPad | 2064 x 2752 | 2048 x 2732; landscape 2752 x 2064 |

Provide the 6.9" and iPad 13" sets. With a 6.9" set, Apple scales it for the smaller iPhone sizes, and the 6.5" set is only needed if you do not provide 6.9". [V] Use Dark or Light consistently; show Dark once if supported.

### iPhone sequence (8 frames, portrait; ASO-STRATEGY.md may reorder and reword)

| # | Overlay caption | What the frame shows | Notes |
|---|---|---|---|
| 1 | Your Mac, from your phone. | Full-screen live Mac desktop with a neutral document and the compact controls dock | Hero. The first 1 to 3 frames appear in search results. [V] |
| 2 | Set up in seconds. | Split composition: Mac menu-bar app with the pairing QR beside the phone camera view | Overlays such as an animated touch point are allowed. [V 2.3.3] |
| 3 | A trackpad in your hand. | Pointer over a text selection with a soft finger-touch marker | Show relative-pointer behaviour. |
| 4 | Type or just talk. | iPhone keyboard beside the microphone dictation state | No private text. |
| 5 | Zoom in on what matters. | Pinch-zoomed small code or text with the pointer visible | Legibility is the point. |
| 6 | Free on your Wi-Fi. Anywhere with Farside Remote. | Route indicator and paywall header, no prices | States a purchase is needed (2.3.2); no prices in screenshots (2.3.7). [V] |
| 7 | Private by design. | Mac menu bar with Stop Sharing, the approval prompt and the on-device speech note | |
| 8 | Works in landscape. | Landscape session with the dock collapsed | Optional. |

### iPad 13" sequence (6 frames)

1 hero landscape session; 2 pairing; 3 zoom and pointer follow; 4 keyboard with modifier row; 5 Free on your Wi-Fi / Farside Remote; 6 windowed or split-view session if supported. Each must be real iPad UI at 2752 x 2064 or 2064 x 2752.

### Content rules for every frame

- 4+ suitable content only (Guideline 2.3.8). Use a clean demo user on the Mac; no notifications, email, messages or browsing history on screen.
- No third-party logos or product names on the streamed desktop (2.3.7, 5.2.1). Use Apple's built-in apps, Terminal, a neutral text editor and a sample document.
- No competitor or other-platform imagery (2.3.10). Do not imitate the App Store, Finder or Apple product UI in a confusing way (5.2.5).
- No cartoon, cow or comic imagery anywhere (see the name section).
- Device bezels only from Apple's licensed marketing assets; flat screenshots are fine.

## 4. App preview video specification and working storyboard

Spec [V]: 15 to 30 seconds, up to 3 previews per size, H.264 (or ProRes 422 HQ), maximum 30 fps, up to 500 MB, `.mov`, `.m4v` or `.mp4`, stereo audio, poster frame defaults to 5 seconds. Accepted iPhone size for 6.9" and 6.5": **886 x 1920** (portrait) or 1920 x 886. iPad 13": **1200 x 1600** or 1600 x 1200. Previews autoplay muted, so the opening must read without sound. Only screen captures of the app itself (2.3.4); narration and text overlays are allowed.

Storyboard, portrait (about 28 seconds, 30 fps):

| Time | Visual | On-screen text |
|---|---|---|
| 0 to 3 s | Live Mac desktop full-screen on the phone | Your Mac, from your phone. |
| 3 to 8 s | Mac shows the QR; phone scans; Mac approves | Scan. Approve. Done. |
| 8 to 14 s | Slide, tap, two-finger scroll, pinch zoom on a document | A trackpad in your hand. |
| 14 to 19 s | Tap the microphone, speak, words appear on the Mac | Type or talk. |
| 19 to 24 s | Route badge switches from Wi-Fi to cellular with the Remote header | Anywhere with Farside Remote. |
| 24 to 28 s | Mac menu bar Stop Sharing, end card with icon and name | Private by design. |

Capture from a real iPhone (QuickTime or Control Center recording), then scale to 886 x 1920; if the source is 60 fps, export at 30. Keep the route change real, not simulated (2.3.1).

## 5. Website and support outline

Tone: plain, calm, no superlatives. Structure mirrors the listing. Web domain proposal: getfarside.com [O after trademark opinion].

| Page | Purpose | Must contain |
|---|---|---|
| Home `/` | Explain in one screen | Headline "Your Mac, from your phone."; the iPhone hero video; two buttons, Download for Mac and App Store; one line each on free local use and Farside Remote; footer links to Privacy, Terms, Support |
| Download `/mac` | Install the companion | Notarized DMG link, version, system requirements (macOS 26 or later), SHA-256, release notes, a 3-step first-run guide with the two permissions (Screen Recording, Accessibility) and why each is needed |
| How it works `/how-it-works` | Trust | Pairing flow, what is encrypted, what the service can and cannot see (a short version of the policy), Stop Sharing |
| Remote `/remote` | Subscription clarity | What Farside Remote adds (relay and network traversal), 7-day free trial, buy in the app, how to manage or cancel in Apple Account settings, refunds handled by Apple. No web checkout. |
| Support `/support` | Required by Apple | Email, phone and legal address (real contact information is required on the Support URL [V]), troubleshooting (permissions, Local Network, firewall, cellular), "Report a problem" instructions, response-time expectation |
| Privacy `/privacy` | Required | The policy in PRIVACY-POLICY.md |
| Terms `/terms` | Required for subscriptions | EULA or custom Terms |
| Security `/security` | Optional | Summary of the design and how to report a vulnerability (security@ address) |
| Updates `/changelog`, `/appcast.xml` | Sparkle | Release notes and update feed |
| Press `/press` | Optional | Icon, screenshots, one-paragraph description, contact |

Add a smart app banner (`apple-itunes-app` meta tag) to the home page once the App Store ID exists. Serve no advertising or analytics scripts in v1 so the policy statements stay true. If Associated Domains and universal links are in scope (another workstream is preparing them), host the `apple-app-site-association` file on the chosen domain over HTTPS with no redirects.

## 6. Localization and accessibility notes

- Launch in English for the US and Canada. Consider French (Canada) for the Canadian storefront; whether Quebec language rules apply is a legal question for counsel [O]. Localized metadata is per language and does not require separate builds.
- Accessibility Nutrition Labels are voluntary today and expected to become required over time. Do not claim VoiceOver for the streamed session canvas; evaluate each label against Apple's criteria first. [V]

## Sources (all checked 2026-09-28)

- Screenshot specifications: https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/
- App preview specifications: https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/
- Platform version information (field limits, Support URL contact requirement): https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/
- Product page guidance (name, subtitle, promo, keywords, IAP field limits): https://developer.apple.com/app-store/product-page/
- Add a new app (name uniqueness and trademark claim FAQ): https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/
- App Review Guidelines 2.3.x, 5.2.x: https://developer.apple.com/app-store/review/guidelines/
- iTunes Search and Lookup API results (name searches, app details): https://itunes.apple.com/search , https://itunes.apple.com/lookup
- USPTO TSDR record for THE FAR SIDE, Reg. 6255846: https://tsdr.uspto.gov/statusview/sn90016156 ; earlier POCKETDESK record (cancelled): https://tsdr.uspto.gov/statusview/rn5228423
- FarWorks trademark listings (secondary): https://uspto.report/TM/90016156/ , https://trademark.trademarkia.com/the-far-side-78488052.html
- Registry WHOIS lookups (Verisign, CIRA, .io, .co) and DNS checks run 28 Sep 2026
- Competitor category data: listings for Workbench, Jump Desktop, Screens 5 (see APP-REVIEW-RISKS.md sources)
