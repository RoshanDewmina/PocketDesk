# Farside: App Store Optimization (ASO) strategy

Prepared Monday 28 September 2026 for the Tuesday 17 November 2026 launch (50 days out). Research only: nothing was registered, reserved, submitted or changed, and no existing repo file was modified. `STORE-LISTING.md` and `LAUNCH-CHECKLIST.md` defer to this file for title, subtitle, keywords, categories, screenshot order and messaging, and rating prompts.

Evidence labels used throughout:

- **[A]** documented by Apple (URL in Sources, fetched 28 Sep 2026).
- **[I]** industry observation or heuristic from a named ASO source; not confirmed by Apple.
- **[M]** measured by me on 28 Sep 2026: the public iTunes Search API (US and CA storefronts, one request per 3.3 s), Apple's public App Store search-hints (autosuggest) endpoint, competitors' public App Store pages, and the iTunes lookup API. Method and limits are in section 2.1.
- **[R]** my reasoning from the above.

Character and byte counts for every proposed string were computed by script, not by hand.

---

## Do this (10 lines)

1. **Title `Farside: Remote Desktop` (23) + subtitle `Control your Mac from iPhone` (28).** It keeps Apple product names out of the app *name* (Apple's trademark rules), uses "Mac" and "iPhone" referentially in the subtitle, and puts the most query combinations into the two strongest fields (section 3.1). The working default "Farside: Mac Remote" is the fallback if you accept a small name-review risk.
2. **Keyword field (98 bytes):** `trackpad,mouse,keyboard,screen,viewer,phone,ipad,access,agent,terminal,home,file,laptop,share,work`. No word repeated from the title or subtitle, no competitor or AI-vendor names, no "VNC" (Farside does not speak VNC).
3. **Categories: Utilities primary, Productivity secondary.** 75% of top-10 slots for Mac-remote and trackpad queries are Utilities apps; the "remote desktop" cluster is Productivity and Business (section 3.3).
4. **Localise for indexing:** English (U.S.) primary, plus English (Canada), French (Canada), French (France) and Spanish (Mexico), all with real translations. Apple lists French (Canada) as Canada's extra language and nine extra languages for the US; en-GB is not one of them (section 3.4).
5. **Fight for the open long tail first:** "control mac from iphone", "control mac", "remote control mac", "trackpad for mac", "mac trackpad", "remote trackpad" ("mac remote" is the stretch). Every Mac-relevant app on the first of those pages has under 250 ratings, and about half of positions 3 to 10 on the others do. Do not chase bare "remote desktop", "vnc" or "remote access": Microsoft, AnyDesk, TeamViewer and RealVNC hold them with 4,000 to 45,000 ratings each [M].
6. **Screenshots 1 to 3 (portrait) carry the search page:** "Control your Mac from your phone" / "Your whole screen is a trackpad" / "Scan. Approve. Connected." Write captions for people, because screenshot-text indexing is unproven. Ship two alternate icons inside the 1.0 binary so product-page tests can run later without a new build.
7. **Ratings:** call `RequestReviewAction` only after a clean, completed session (the third such session, never on an error or paywall screen), add a Settings link to the write-review URL, and never solicit, incentivize or gate by sentiment (Guideline 5.6.1). Stars show only after 5 ratings in a storefront.
8. **Pre-order and featuring:** treat pre-order as a free by-product of the approved 3 Nov build (a window of days, not weeks), and file a Featuring Nomination (type "App Launch") the day the app record exists, target Fri 9 Oct.
9. **Apple Ads Advanced, CA$100/month ceiling (CA$3.29/day):** 13 exact-match keywords plus a Search Match discovery ad group (section 5.4). Expect about 35 installs; it buys keyword data and early velocity, not scale.
10. **Measure and loop:** watch impressions, product page views, conversion rate by source type, peer-group benchmarks, per-custom-page and per-campaign-link results, and change metadata at most once per 14 days per storefront (section 6).

---

## 1. How App Store search works in 2026

### 1.1 What is indexed

| Field | Limit | Used for search? | Evidence |
|---|---|---|---|
| App name | 30 characters | Yes, the heaviest text field | [A] Apple: results depend on "text relevance (matches for your app's title, subtitle, keywords, and primary category)" plus user behaviour. Field weighting (title, then subtitle, then keywords) is [I] (AppTweak, updated 28 Jan 2026; SplitMetrics, 1 Sep 2025) |
| Subtitle | 30 characters | Yes | [A] |
| Keyword field | 100 bytes, comma-separated, no spaces between terms, each term more than 2 characters | Yes | [A] product page guidance and App Store Connect platform-version reference |
| Primary category | one | Yes (listed as text relevance) | [A] |
| Secondary category | one | Not listed by Apple as a relevance input | [R] |
| Developer (company) name | n/a | Yes: apps are "searchable by app name and company name" | [A] platform-version reference (via page fetch) |
| In-app purchase display name | 30 characters (IAP page) | Unproven | [I] Asodesk: informal 2019 test of about 50 apps; Apple does not document it |
| Additional localizations | per locale | Yes, in the storefronts that support them (section 3.4) | Supported languages [A]; indexing behaviour [I] (MobileAction, 15 Apr 2026; aso.dev) |
| Description | 4,000 | Not listed among search inputs; Apple says not to add keywords for search; it is used for web search results after release and feeds the LLM tags below | [A] |
| Promotional text | 170 | No | [A] "does not affect search ranking" |
| What's New | 4,000 | No | [R] |
| Screenshots and previews | 10 / 3 | The first one to three (or the preview) appear in search results and drive tap-through. Whether caption *text* is indexed is contested | [A] for display; see 1.3 for the text question |
| In-app events | up to 10 published | Appear in search results (event cards for people who already have the app, screenshots for those who do not) | [A]; AppTweak says events are indexed for relevance [I] |
| Custom product pages | up to 70 | You can assign keywords (chosen from your keyword field) so a custom page shows in search instead of the default page for those keywords | [A] |
| App Store Tags | generated | LLM-generated from your metadata, description, category and screenshots, human-reviewed, shown in search results and tag pages, editable in App Store Connect | [A] WWDC25 session 328 |

### 1.2 Ranking signals

**Apple-documented [A]:** text relevance (title, subtitle, keywords, primary category) and user behaviour ("downloads, ratings and reviews, and more"). Apple says few ratings "may discourage" downloads and a strong summary rating helps discoverability; the summary rating is per territory. In its research paper "Scaling Search Relevance" (arXiv 2602.23234, Feb 2026, covered by 9to5Mac on 6 Mar 2026) Apple describes a ranker that balances behavioural relevance (what people tap and download) with textual relevance (semantic fit to the query), and reports that adding LLM-generated textual-relevance labels raised conversion (search sessions with at least one download) by 0.24% worldwide in an A/B test, with the largest gains on tail queries. The paper does not say which metadata fields the model reads.

**Industry heuristics [I], not confirmed by Apple:** download velocity (recent installs weigh more than lifetime installs), per-keyword conversion, retention and uninstall rate, crash rate, update cadence (AppTweak suggests every 2 to 4 weeks), a temporary "new app" uplift, and ratings (AppTweak: under 3.5 stars hurts visibility, above 4.0 correlates with higher rank). Treat each as a reason to behave well, not as a lever with a known size.

### 1.3 Recent changes and what to make of them

| When | Change | Evidence level | Meaning for Farside |
|---|---|---|---|
| June 2025 | Reports that screenshot caption text influences ranking | Contested. SplitMetrics lists it as an update; AppTweak (Jan 2026) says there is "no official confirmation"; ConsultMyApp tested 64 screenshot-derived phrases across 8 large apps: 36 did not rank, 27 were already explained by title, subtitle or keywords, 1 was unexplained. Apple has not documented it | Write captions as conversion copy that happens to contain the real words people use. Do not stuff |
| 9 Jun 2025 (WWDC25) | App Store Tags: LLM-generated from metadata, description, category and screenshots, human-reviewed, editable in App Store Connect | [A] | After the first submission, open App Information, read the tags Apple attached, and deselect any that mislead (for example TV remote or VPN). Deselecting removes the tag everywhere on the store |
| 30 Jul 2025 (reported) | Custom product page keywords for organic search; no review needed to change keywords | [A] page; date [I] | The keyword field must already contain the words each custom page will claim (section 4.6) |
| 29 Oct 2025 (reported) | Custom product pages raised to 70 per app | [A] (limit); date [I] | More than we need |
| Feb to Mar 2026 | Apple LLM-relevance research (+0.24% conversion, gains on tail queries) | [A] | Semantic fit to natural-language queries such as "control my mac from my phone" matters more; write the subtitle, first screenshot and description opening in that language |
| 8 Jun 2026 (WWDC26) | Personalized Collections and App Notes (why an app is recommended) rolling out in English for the US from June, more regions later | [A] Apple Newsroom | Recommendation surfaces read your metadata and installs; accurate tags and a clear description are the only handle |
| Fall 2026 (with iOS 27) | Asset Library, product page header, and search-result creative assets (images or video shown in search); a product page preview tool; retention messaging and subscription bundles | [A] WWDC26 App Store guide; MobileAction 18 Aug 2026 | Optional. If you skip the search-result asset, your screenshots, previews and events show instead. Revisit after launch |

### 1.4 What this means

1. Metadata is a small, fixed budget (60 visible characters plus 100 bytes), so the choice of words is most of the game.
2. Behaviour signals dominate once you are on the page: tap-through from the icon, first three screenshots and rating, then conversion. A page that converts at a higher rate than its neighbours climbs; a page that does not, sinks, whatever its keywords.
3. A new app with zero ratings cannot out-rank incumbents on volume terms. It can win terms where the incumbents are weak or absent and where the query is specific enough for semantic matching to help (section 2.2).

---

## 2. Keyword research

### 2.1 Method and limits

- **Who ranks [M]:** for about 100 queries I pulled the US top 25 from the iTunes Search API (10 queries also for the CA storefront) and recorded name, seller, category and rating count. Ratings count is my proxy for cumulative demand and incumbent strength.
- **Popularity signal [M]:** Apple's public autosuggest endpoint (`search.itunes.apple.com/WebObjects/MZSearchHints.woa/wa/hints`, storefronts US 143441 and CA 143455). Apple only suggests phrases with enough search activity, so I score each phrase: `●●●` = offered within the top 3 suggestions for some prefix; `●●○` = offered within the top 10; `●○○` = only app names or 1 to 2 suggestions; `○○○` = nothing suggested. This is a coarse presence test, not a volume. Apple's real 5 to 100 popularity score is only visible inside an Apple Ads Advanced account; pull it for these phrases once the app record exists.
- **Limits:** the iTunes API ranks heavily on title-text match (for example "Control - Mac Remote Control", 5 ratings, is #1 for "remote control mac"), while the real store also weighs downloads and ratings, so a 0-rating app will not sit where the API puts it. Use the API for "who is on this page", not "where will I rank". Autosuggest mixes query logs with app names, so `●○○` can hide real demand (for example "remote mac"). No private ASO tool data (Sensor Tower, AppTweak, Appfigures, MobileAction) was available; their popularity scores are paid.

### 2.2 The market map [M]

Two different result pages hide inside "remote desktop for Mac".

| Cluster | Top-10 slots by category (US, 28 Sep 2026) | Who owns it | Openness for a new app |
|---|---|---|---|
| **Remote desktop / remote access** (10 queries, 100 slots) | Productivity 36, Business 35, Utilities 27 | Windows App 7.8k ratings, AnyDesk 28.1k, TeamViewer 44.6k, RealVNC 15.3k, Splashtop 4.6k, RemotePC 3.5k, Jump Desktop 1.7k, Screens 5 551, Workbench 182, RustDesk 76 | Locked at the head. The premium native segment is small: Jump Desktop (2010) has 1.7k US ratings, Screens 5 (Dec 2023) 551, Workbench (Mar 2026, heavy press) 182 |
| **Mac remote / trackpad / input device** (15 queries, 150 slots) | Utilities 113 (75%), Productivity 28 | Remote Mouse 18.7k and Remote, Mouse and Keyboard 14.3k hold #1 and #2 on most terms | Partly open: on the winnable queries about half of positions 3 to 10 are apps with under 250 ratings (Control, Rimote, FullControl, Airnest, PhoneDeck, ReMac, Macky and others; Gateway, Helm and Porta surface in autosuggest). The other half are established (RealVNC, AnyDesk, Mouse-Keyboard 2.5k, Mobile Mouse 2.5k). "remote mac" itself is the hardest: 9 of its top 10 have over 1,000 ratings |
| **AI-agent remote** | "ai agent", "claude code", "codex": LLM chat apps fill the top 10 (Claude 270k, ChatGPT 10.7M) | Small remote-agent apps sit lower: Happy (Codex and Claude Code, Developer Tools, 1,017 ratings, 4.87), Codex Relay 56, Codex AI: Remote Codex 30, Macky 19, Claude Code Notifier Companion 8 | Demand exists ("codex remote" is a top-4 suggestion for "codex") but it hangs on third-party brand names Farside must not put in metadata |

Other things the data says:

- **Closest new rival:** Remote Mac Desktop Control (released 13 Aug 2026, 1 rating, Utilities). Subtitle "Trackpad, Keyboard and Screen"; IAPs Premium Monthly US$7.99, Annual US$47.99, Lifetime US$99.99. It is the only listing whose pitch overlaps Farside's almost exactly, and its name is now an autosuggest entry for "remote mac".
- **Workbench** (Astropad, released 24 Mar 2026, 182 US ratings, 4.82) uses the subtitle "Access your Mac from anywhere" in Utilities. Six months and tier-one press produced about 180 US ratings, so plan Farside's first year in tens to low hundreds of ratings, and plan the store page for conversion, not volume [R].
- **New entrants:** a dozen or more small "Mac remote" apps appeared in 2025 to 2026 (Control Feb 2025, Macky Feb 2026, Rimote Jul 2026, Remote Mac Desktop Control Aug 2026, plus Gateway, Helm, Porta, Remouse, Cmdora, Flux Remote, Airnest, PhoneDeck). The long tail is filling up; being early and converting well matters.
- **Name collision on search:** a new Utilities app called "Farroom: Remote Desktop" (0 ratings) appears in autosuggest for "remote desk" in both US and CA. The pattern "Farside: Remote Desktop" would sit beside it. Low risk, worth knowing.
- **Pollution:** "screen sharing", "screen mirroring", "remote control" and "sidecar" pages are dominated by TV-cast, TV-remote and unrelated apps. Ranking there brings the wrong audience.
- **Category evidence:** input-device apps are Utilities; remote-desktop apps split across Productivity, Business and Utilities; agent-remote apps are Developer Tools.

### 2.3 Candidate keywords (73)

Legend. Relevance: H high, M medium, L low. Competition: **Locked** (several relevant apps with more than 4,000 ratings in the top 10), **Hard** (one or two relevant giants, many mid or weak apps), **Open** (relevant apps in the top 10 mostly under 300 ratings), **Polluted** (top 10 mostly irrelevant). Verdict: **T** title, **S** subtitle, **K** keyword field, **C** custom page or Apple Ads test, **D** description and screenshot copy only, **X** skip. Ratings are US counts [M].

| # | Keyword | Rel | Popularity | Competition and who owns it | Verdict |
|---|---|---|---|---|---|
| 1 | remote desktop | M | ●●● | Locked: Windows App, AnyDesk, Chrome, TeamViewer, RealVNC, Splashtop | T word; do not expect page one |
| 2 | remote desktop mac | H | ●●○ | Locked: RealVNC, AnyDesk, TeamViewer, Splashtop; Jump #8, Screens 5 #9 | T+S tokens; long game |
| 3 | remote desktop for mac | H | ○○○ | Locked | Covered by tokens |
| 4 | remote desktop control | M | ●●○ | Locked: AnyDesk, Windows App, Remote Mouse, TeamViewer | Covered (remote, desktop, control all in title and subtitle) |
| 5 | remote desktop iphone | M | ○○○ | Locked | Covered by tokens |
| 6 | remote access | M | ●●● | Locked: AnyDesk, TeamViewer, Windows App, RealVNC, Splashtop | K: access |
| 7 | remote access mac | H | ○○○ | Locked at #1 (RealVNC), several under 500 below | Covered by tokens |
| 8 | remote pc | L | ●○○ | Locked (Windows) | X: Farside does not control PCs |
| 9 | vnc, vnc viewer, vnc mac | L | ●●● | Locked: RealVNC 15.3k; Screens 5 551 | X: not VNC, wrong audience, Guideline 2.3.7 |
| 10 | screen sharing | M | ○○○ | Polluted: 9 of 10 TV mirroring | X |
| 11 | mac screen share | H | ●●● | Mixed: AnyDesk #1, TV mirroring 6 of 10 | K: share |
| 12 | screen mirroring mac | L | ○○○ | Polluted: 10 of 10 TV | X |
| 13 | remote screen | M | ●●○ | Locked: Splashtop, TeamViewer, AnyDesk, RealVNC | Covered by tokens |
| 14 | screen viewer, mac screen viewer | H | ●●○ / ○○○ | Open: for "mac screen viewer" Screens 5 (551) is #1, RealVNC #2, the rest under 900 | K: screen, viewer |
| 15 | remote login | L | ●○○ | Locked, off-topic | X |
| 16 | mobile remote access | L | ○○○ | Locked | X |
| 17 | control computer from phone | M | ○○○ | Locked: Splashtop, Link to Windows 16k, AnyDesk | Semantic match only |
| 18 | phone remote for computer | L | ○○○ | Locked, TV noise | X |
| 19 | mac remote | H | ●●● | Hard: Remote Sunrise 14.3k and Remote Mouse 18.7k at #1 to #2; below them tiny apps (Rimote 1, Control 5, Airnest 1, FullControl 221) share the page with RealVNC 15k and AnyDesk 28k | Stretch target (T remote + S mac) |
| 20 | remote mac | H | ●○○ (app names) | Locked-hard: 9 of the top 10 have over 1,000 ratings (Remote Mouse, Sunrise, RealVNC, AnyDesk, TeamViewer, Splashtop, iTunes Remote and others) | Secondary; reached through tokens, expect months |
| 21 | remote control mac, mac remote control | H | ●●● | Open behind incumbents. "mac remote control": #1 Control (5 ratings), #2 Rimote (1), Sunrise and Remote Mouse #3 to #4. "remote control mac": Sunrise and Remote Mouse #2 to #3, RealVNC #4, FullControl (221) #5. TV remotes appear from #6 | **Core target** (remote, control, mac all covered) |
| 22 | control mac | H | ●●○ | Open: Control - Mac Remote Control (5 ratings) #1 | S: control + mac |
| 23 | control my mac | H | ●○○ | Open: FullControl 221 #1 | Covered |
| 24 | control mac from iphone | H | ○○○ | **Open**: every Mac-relevant app in the top 10 has under 250 ratings (PhoneDeck 2, ReMac 1, Control 5, FullControl 221, Rowmote Pro 106, Macky 19, Rimote 1); the four apps above 1,000 ratings are TV-remote apps | **Primary long tail**: subtitle is an exact phrase match |
| 25 | use mac from phone | M | ○○○ | Off-topic top 10 (Link to Windows 16k); Rowmote 106 | Semantic; description |
| 26 | mac from anywhere | M | ○○○ | Hard: AnyDesk 28k #1 | D only: "anywhere" needs the paid tier (Guideline 2.3.2) |
| 27 | access my mac | M | ○○○ | Polluted: health and government portals | X |
| 28 | remote mac desktop control | n/a | ●●● | Rival's app name (1 rating, launched 13 Aug 2026) | X: competitor name |
| 29 | mac control | L | ●●○ | Ambiguous | X |
| 30 | mac mini remote, remote mac mini | M | ○○○ | Remote Mouse Pro #1; TV noise 2 to 3 of 10 | Ads and custom page later; K3 has "mini" |
| 31 | headless mac | M | ○○○ | Polluted (game); Rowmote 106, FullControl 221 | C: agents page only |
| 32 | ipad mac remote | M | ○○○ | Polluted: 5 of 10 TV | X |
| 33 | mac remote app | M | ○○○ | Hard | X: "app" is a banned filler word |
| 34 | trackpad | H | ●●● | Hard: Remote Mouse #1, Remote Sunrise #5, others under 100 | K: trackpad (the differentiator) |
| 35 | trackpad for mac | H | ●●● | **Open**: Tracepad (15 ratings) #1; Remote Mouse, Mouse-Keyboard 2.5k and Sunrise fill #2 to #4; five of the next six are under 250 | Tokens (mac in S, trackpad in K) |
| 36 | mac trackpad | H | ●●● | Open-mid: Remote Mouse, Sunrise, the rest under 2.6k | Tokens |
| 37 | remote trackpad | H | ●●○ | **Open**: Remote Trackpad (0 ratings) #1, Remote Mouse #2 | Tokens (remote in T, trackpad in K) |
| 38 | phone as trackpad, use iphone as trackpad | H | ○○○ | Open: 8 of 10 under 300 ratings | Screenshot 2 wording; semantic |
| 39 | remote mouse | M | ●●● | Locked: Remote Mouse 18.7k, Sunrise 14.3k | K: mouse |
| 40 | remote mouse mac, remote mouse for mac | H | ●●● | Hard: incumbents, then Remote Mouse for Mac (0), Mouse-Keyboard 2.5k | Tokens |
| 41 | mac mouse | L | ●○○ | Ambiguous (hardware) | X |
| 42 | iphone as mouse for mac | M | ○○○ | Open: Mobile Mouse 2.5k | Semantic |
| 43 | air mouse | L | ●●○ | Different product | X |
| 44 | remote keyboard | M | ●●● | Open (7 of 10 under 300 ratings, top one 37) but TV keyboards | K: keyboard |
| 45 | keyboard for mac | L | ●●○ | Ambiguous (hardware) | X, covered by tokens |
| 46 | computer remote | M | ●●○ | Hard: Remote Mouse, Sunrise, AnyDesk | K3 only ("computer") |
| 47 | presentation clicker, keynote remote | L | ●●○ | Keynote itself #1 | X: not the product |
| 48 | voice dictation mac | M | ○○○ | Polluted by recorders; Wispr Flow 16k | D: differentiator copy, not a keyword |
| 49 | dictate to mac | M | ○○○ | Voice to Text 11k | D |
| 50 | voice typing mac | L | ○○○ | Wispr Flow 16k | X |
| 51 | clipboard sync | L | ●●○ | Open, but a different intent (clipboard managers) | D |
| 52 | universal clipboard, shared clipboard | L | ●●○ / ○○○ | Apple's own feature name | X |
| 53 | wake on lan | M | ●●● | Open: Wolow 1.3k | X unless the feature ships (Guideline 2.3.1) |
| 54 | file transfer mac | L | ○○○ | Polluted | X: feature not shipped |
| 55 | sidecar | L | ●●○ | Polluted; Apple's feature name | X |
| 56 | ai agent | M | ●●● | Locked by LLM chat apps | K: agent (token, for the agents page) |
| 57 | ai coding agent | M | ●●○ | Locked by LLM apps | C |
| 58 | vibe coding | L | ●●● | Different intent (app builders) | X |
| 59 | claude code | M | ○○○ | Locked: Claude 270k; Happy 1,017 | X: Anthropic trademark (Guidelines 2.3.7, 5.2.1) |
| 60 | codex | M | ●●● | Locked: ChatGPT | X: OpenAI trademark |
| 61 | codex remote | M | ●●○ | Open: Codex AI Remote Codex 30, Codex Relay 56, Happy 1,017 | X in metadata (third-party mark); ad test only after counsel |
| 62 | cursor ai | L | ●●○ | Brand | X |
| 63 | agent monitor | M | ○○○ | Open: all under 5 ratings, Pulseway 616 | C: ads or agents-page test |
| 64 | remote terminal | M | ●●○ | Locked-mid: Termius 19k, AnyDesk, RealVNC | K: terminal |
| 65 | ssh | L | ●●● | Different product (SSH clients) | X |
| 66 | tailscale | L | ●●○ | Brand | X |
| 67 | no account remote desktop | M | ○○○ | Locked | D: copy angle |
| 68 | private remote desktop | M | ○○○ | Locked | D |
| 69 | secure remote desktop | M | ○○○ | Locked (Jump 1.7k) | D |
| 70 | qr code remote | L | ○○○ | Polluted: QR readers | X |
| 71 | remote desktop free | M | ○○○ | Locked | X: "free" is generic; use promotional text |
| 72 | remote work | L | ●●● | Polluted: job boards | X |
| 73 | home computer access | M | ○○○ | Locked (Splashtop and others) | K: home + access (home-file custom page) |

Reading the table: the winnable set is rows 21 to 24 and 34 to 38, with 19 and 40 as stretches. Every one needs the tokens **remote** or **control**, **mac**, and one of **trackpad**, **mouse**, **screen**. Those words plus "desktop" for the head and "iphone" for natural language are the whole title, subtitle and keyword design.

### 2.4 Trademark and rules that shape the list

- **Apple marks in the name [A]:** Apple's third-party guidelines let developers use an Apple word mark "in a referential phrase" ("for", "runs on", "compatible with") but say the mark "must not be part of the product name" and bar using Apple marks "as or as part of a company name, trade name, product name, or service name". Apple's App Store marketing guidelines say not to put Apple product names in an app name (their examples are "iPhone" and "Apple Vision Pro"). "Mac" is an Apple trademark on the same footing. Many live apps break this in practice (Rimote: Mac Remote Control, FullControl: Remote for Mac, Control - Mac Remote Control) [M], so App Review appears lenient in practice [R], but a rejection in the 3 Nov to 10 Nov window would cost the launch date. That is why the recommended name omits "Mac".
- **Apple marks in the subtitle and keywords:** referential use ("your Mac", "from iPhone") is the pattern Apple's guideline describes, and is standard on live listings (Remote, Mouse and Keyboard uses "for Apple TV, Mac, PC and iPad" as its subtitle [M]). Spell them correctly: Mac, iPhone, iPad. Do not use "MacBook", "iMac" or "Sidecar" as keywords, and do not use the Apple logo in the icon or screenshots.
- **Other people's marks [A]:** Guideline 2.3.7 bars packing metadata "with trademarked terms, popular app names, pricing information, or other irrelevant phrases"; the keyword field must not contain names of other apps or companies; Guideline 4.1(c) bars another developer's product name in your name; 5.2.1 bars protected third-party material. So: no competitor names (Workbench, Jump, Screens, RustDesk, TeamViewer, AnyDesk, Splashtop, Parsec) and no Claude, Codex, ChatGPT, Cursor or Tailscale in the name, subtitle or keywords. Other apps do it (Happy: Codex & Claude Code App is live [M]); that is not a defence, and a takedown mid-launch would cost more than the keyword is worth. Factual compatibility statements belong on the website, not in store metadata.
- **Accuracy [A]:** keywords must "accurately describe your app" (2.3.7); anything advertised must exist in the submitted build (2.3.1); subscription requirements must be clear in the description, screenshots and previews (2.3.2). Hence no "VNC", no "wake on LAN", no "file transfer", no "AI agent take-over" until they ship, and no "from anywhere" in the subtitle because that needs the paid tier.
- **The Far Side:** `LAUNCH-CHECKLIST.md` already tracks the FarWorks mark. For ASO purposes: always one word "Farside", never "Far Side" in copy, keywords or URLs, and no cartoon imagery.
- **Format rules [A]:** each keyword more than 2 characters (so a bare "ai" is not allowed; use "agent"); no spaces after commas; avoid plurals of words you already include, category names, "app", duplicates and special characters.

---

## 3. Concrete metadata proposals

### 3.1 Five title and subtitle combinations

Coverage is scored against 19 probe queries as a simple token model: remote desktop; remote desktop mac; remote desktop control; remote access; mac remote; remote mac; remote control mac; control mac; control mac from iphone; trackpad for mac; mac trackpad; remote trackpad; remote mouse mac; remote keyboard; mac screen viewer; mac screen share; remote control; computer remote; phone as trackpad. **In title + subtitle** = every query word is already in the two strongest fields (filler words such as for, from, your, use, as ignored). **With keyword field** = covered once the option's keyword field is adjusted to drop duplicated words and add "desktop", "control" or "iphone" where the option lacks them. Apple does not publish how it combines words across fields, so read this as a tie-breaker between options, not a prediction.

| Option | Title (chars) | Subtitle (chars) | In title + subtitle | With keyword field | Apple product name in the app name? | Notes |
|---|---|---|---|---|---|---|
| **A (recommended)** | `Farside: Remote Desktop` (23) | `Control your Mac from iPhone` (28) | 9 of 19 | 18 of 19 | No (subtitle only, referential) | Lowest trademark exposure, best use of the two strong fields; the subtitle is an exact match for the top natural-language query and makes clear the app is for Mac. It claims nothing that needs the paid tier. "Remote Desktop" could attract Windows and RDP seekers, so the subtitle and screenshot 1 must say Mac |
| A2 (subtitle swap) | `Farside: Remote Desktop` (23) | `Use your Mac from your phone` (28) | 4 of 19 | 17 of 19 | No | Friendlier to non-technical readers (students, "file from home"); moves "control" and "iPhone" out of the strong fields. This is the `STORE-LISTING.md` working subtitle. Good month-2 A/B |
| B | `Farside: Mac Remote` (19) | `Screen, trackpad and voice` (26) | 5 of 19 | 17 of 19 | Yes | The working default. Exact adjacent phrase "mac remote". Mirrors the rival's "Trackpad, Keyboard and Screen" |
| C | `Farside: Remote for Mac` (23) | `Trackpad, screen & voice input` (30) | 5 of 19 | 17 of 19 | Yes ("for Mac" is Apple's referential form, but Apple says the mark must not be part of the product name) | Same coverage as B; "for" is filler |
| D | `Farside: Remote Mac Trackpad` (28) | `Screen, keyboard and voice` (26) | 6 of 19 | 18 of 19 | Yes | Puts the differentiator in the title; undersells "see your screen"; longest title |
| E | `Farside: Remote Access` (22) | `Your Mac's screen and trackpad` (30) | 6 of 19 | 18 of 19 | No | Takes the head word "access" into the title; collides head-on with AnyDesk and TeamViewer phrasing |

The only probe that no option covers is "computer remote" (it needs the word "computer", which is in K3).

Why A: the winnable queries all need "remote" or "control", "mac", and a device word. A places "remote", "desktop", "control", "mac" and "iphone" in the title and subtitle and leaves the keyword field for input-device words. Month-2 decision rule: do not move to a "Remote Control" title (the "remote control" page is full of TV remotes); if "control mac from iphone" and "remote control mac" reach the top 10 but the wording underperforms with non-technical readers, keep the title and A/B the subtitle (A against A2).

Titles and subtitles are version-level fields: changing them needs a new app version (about a 24-hour review). They cannot be split-tested in Apple's product page tests (those cover icon, screenshots and previews only), so test them in sequence, at least 14 days apart, with a rank tracker.

### 3.2 Three keyword-field strings (all comma-separated, no spaces, no word repeated from option A's title or subtitle, singular forms)

| Set | String | Bytes | Use |
|---|---|---|---|
| **K1 launch core** | `trackpad,mouse,keyboard,screen,viewer,phone,ipad,access,agent,terminal,home,file,laptop,share,work` | 98 | Ship in 1.0. Carries the input-device words, the three custom-page clusters (agents: agent, terminal; work: laptop, work; home file: home, file) and "access" and "share" for the head terms |
| K2 agent-forward | `agent,coding,terminal,monitor,trackpad,mouse,keyboard,screen,viewer,phone,ipad,access,share` | 91 | Swap in when the AI-agent features actually ship (v1.1 or later): adds "coding" and "monitor" for the agents page and drops the home and work words |
| K3 home and work test | `home,work,laptop,computer,file,mini,trackpad,mouse,keyboard,screen,viewer,phone,ipad,access,share` | 97 | Alternative for a second-storefront or month-2 test: broadens to "computer" and "mini" (mac mini remote) |

Notes:

- "iphone" is deliberately absent because it is in the subtitle; "phone" and "ipad" are in the field because tokens in different fields combine [I].
- "dictation" and "voice" are left out: the queries have almost no measurable volume (rows 48 to 50) and semantic matching plus the description will carry them.
- Terms the field would love to have but must not: competitor names, Claude, Codex, ChatGPT, Cursor, VNC.
- Apple counts bytes; accented letters count as 2 (see the Spanish and French sets below).

### 3.3 Categories

**Primary Utilities, secondary Productivity.**

Evidence [M]: for the 15 Mac-remote and input-device queries, 113 of 150 top-10 slots are Utilities and 28 are Productivity. For the remote-desktop cluster the split is Productivity 36, Business 35, Utilities 27. Primary category is a listed text-relevance input [A], so matching the category that the winnable result pages already share is worth having. Utilities is also where the direct competitors sit: Workbench, Screens 5, AnyDesk, RustDesk, Remote Mouse, Remote Mac Desktop Control and the new small apps. Business would put Farside beside Jump and Windows App and is a worse fit for a free consumer tool.

Secondary is not documented as a ranking input [R]; use it for browse and credibility. Productivity suits students and remote workers. Revisit in month 2: if the AI-agent features ship and the agents page performs, test Developer Tools as secondary (that is where Happy, Macky and Codex Relay list themselves). Categories can change with any version.

### 3.4 Localisation: which extra locales count, and how to use them

Apple's App Store localizations reference [A] lists, per storefront, the default language and the additional languages a listing can show:

| Storefront | Default language | Additional languages Apple lists |
|---|---|---|
| United States | English (U.S.) | Arabic, Chinese (Simplified), Chinese (Traditional), **French** (Apple lists plain "French", which aso.dev identifies as fr-FR), Korean, Portuguese (Brazil), Russian, **Spanish (Mexico)**, Vietnamese |
| Canada | English (Canada) | **French (Canada)** |
| United Kingdom | English (U.K.) | none |
| Australia | English (Australia) | English (U.K.) |

Apple documents which languages exist per storefront, not how its search indexes them. That indexing (each extra locale adds its own title, subtitle and 100-byte keyword field to the storefront's index) is [I]: MobileAction (15 Apr 2026) and aso.dev describe it and say it is observation, not documentation. Two corrections to the working assumption in the brief: **en-GB is not one of the extra languages for the US or Canada** (Apple lists English (U.K.) as an extra language for Australia and, for example, Germany); the US extras are the nine above, Canada's is French (Canada).

Plan:

| Locale | Purpose | What to write |
|---|---|---|
| English (U.S.) primary | US default and fallback | Option A and K1 |
| English (Canada) | Canada default | Same copy as US. Do not remove core words: it is not confirmed whether Canada also indexes the primary en-US fields once an en-CA locale exists. Test: after week 2, swap 3 low-value tokens in en-CA only and see if both sets rank in Canada with a tracker |
| French (Canada) | Canada extra keyword field, and the market's second language | Real translation (draft below, needs native review; Quebec language rules are a counsel question in `STORE-LISTING.md`) |
| French (France) | The US storefront indexes it; reuse the French copy | Same text, keyword field tuned for France spelling |
| Spanish (Mexico) | The US storefront indexes it; large Spanish-speaking US audience | Real Spanish name, subtitle and description; the keyword field may also carry English overflow tokens that did not fit in K1 |

Draft copy (verify with a native speaker; counts are script-checked):

| Locale | Name | Subtitle | Keyword field |
|---|---|---|---|
| es-MX | `Farside: Escritorio Remoto` (26) | `Controla tu Mac desde iPhone` (28) | `ratón,teclado,pantalla,acceso,dictado,voz,computadora,portátil,visor,coding,monitor,computer,mini` (99 bytes; the English tokens coding, monitor, computer and mini are the K2 and K3 overflow that is not in the en-US field) |
| fr-CA and fr-FR | `Farside : Bureau à distance` (27 characters, 28 bytes) | `Contrôlez votre Mac à distance` (30 characters, 32 bytes) | `pavé tactile,souris,clavier,écran,accès,dictée,ordinateur,portable,visionneuse,télécommande` (97 bytes) |

Cautions:

- People whose device language is Spanish or French will see these product pages, so the name, subtitle and description must be genuinely translated. Only the keyword field is invisible.
- Do not fill Arabic, Chinese, Korean, Portuguese, Russian or Vietnamese with English keyword filler. Those readers would see an untranslated page (worse conversion, worse quality signals) and stuffing irrelevant terms risks Guideline 2.3.7. Add them later, with real translations, if the data shows demand.
- Screenshots for a new locale inherit the primary language's until you upload localized ones. Localise the first three later if the French or Spanish traffic is meaningful.
- Subscription display names must not contain diacritics or special characters [A] (auto-renewable subscription page), so keep the French and Spanish subscription names ASCII ("Farside Anywhere - Mensuel", "Farside Anywhere - Mensual").

### 3.5 In-app purchase names that help search

- The in-app purchase display name is 2 to 30 characters and the description up to 45 [A] (In-App Purchase information page). The auto-renewable subscription page I fetched lists no numeric limit, and `SUBSCRIPTION-SETUP.md` quotes 35 and 55, so check the counter in App Store Connect; every string below fits 30 and 45 anyway.
- IAP names appear in the product page's "In-App Purchases" list next to the price (visible on Screens 5, Remote Mac Desktop Control, Splashtop, Duet and others [M]). Whether they help search is [I]/unproven, so choose for clarity first.
- Recommendation: `Farside Anywhere` is the group and marketing name (PRODUCT D41, 30 Sep 2026; consistent with `SUBSCRIPTION-SETUP.md`, the paywall and the description). Optional, low-risk hedge for the unproven indexing: name the two products `Remote Access - Monthly` (23) and `Remote Access - Yearly` (22), because "access" is the strongest head word missing from the title and subtitle. If you would rather keep every doc consistent, `Farside Anywhere - Monthly` (26) and `Farside Anywhere - Yearly` (25) from `SUBSCRIPTION-SETUP.md` are fine. Use a plain hyphen, not an en dash.
- Descriptions (45 max): monthly `Reach your Mac from anywhere, any network` (41); yearly `Best value. Reach your Mac from anywhere.` (41). No prices in names or descriptions.
- Promotional in-app purchases can show in search and on the product page after release [A]; consider promoting the yearly plan once the app is live, and only if the paywall it opens satisfies Guideline 3.1.2(c).

### 3.6 Copy that is not indexed but drives the tap

- **Promotional text (170, editable without a new version):** `Free on your Wi-Fi. Add Remote Access to reach your Mac from anywhere. No account, no setup. Try it free for 7 days.` (116). Keep the trial mention here and in the description rather than in screenshots or the subtitle (Guideline 2.3.7 warns against "terms" in metadata that is not specific to the type).
- **Description opening (the first three lines are all most people read):** `Farside shows your Mac's screen on your iPhone or iPad and turns the whole screen into a trackpad, with a keyboard and voice dictation to match.` (144). It gives the LLM tag generator the real nouns (screen, trackpad, keyboard, dictation) and states "Mac" and "iPhone". Keep the rest of the working description in `STORE-LISTING.md`.
- **What's New (1.0):** `Welcome to Farside. See and control your Mac from your iPhone or iPad, free on your Wi-Fi. Add Remote Access to reach it from anywhere.` (135).
- **Seller name:** the company name is searchable [A]. If you form a legal entity, a name containing "Farside" (subject to the trademark opinion) would add a brand token; an individual account adds nothing.
- **Do not repeat** the brand or the title words in the promotional text for search reasons: it is not indexed.

---

## 4. Conversion

### 4.1 Screenshot storyboard (portrait, iPhone 6.9"; sizes and rules are in `STORE-LISTING.md` section 3)

Search shows the first one to three portrait screenshots (or an autoplaying preview) beside the title, subtitle and rating [A]. Design the first three as one read-in-2-seconds unit, with captions large enough to read at one-third size (aim for about 6% of image height for the cap height, at most 6 words). Captions are for people; screenshot text is not a proven ranking input.

| # | Caption (chars) | Frame | Job |
|---|---|---|---|
| 1 | `Control your Mac from your phone` (32) | Full-screen live Mac desktop on the phone, a visible pointer, a small "Free on your Wi-Fi" chip | State the product and the platform ("Mac", "phone") in the user's own words; echo the top natural-language query |
| 2 | `Your whole screen is a trackpad` (31) | Pointer over selected text with a soft touch marker and a haptic cue icon | Show the differentiator no rival leads with |
| 3 | `Scan. Approve. Connected.` (25) | Split: Mac menu-bar pairing code beside the phone camera | Remove the two fears: setup and account. Add "No account" as a small chip |
| 4 | `Talk instead of typing` (22) | Microphone active, words landing in a Mac document | Voice dictation into the Mac |
| 5 | `Zoom follows your pointer` (25) | Pinch-zoomed small text with the view tracking the pointer | Legibility on a small screen |
| 6 | `Free on Wi-Fi. Anywhere with Remote Access.` (43) | Route indicator and paywall header, no prices | Satisfies 2.3.2 and sets honest expectations, which protects ratings |
| 7 | `Private by design` (17) | Approval prompt and Stop Sharing | Trust |
| 8 | `Works on iPad too` | Real iPad UI, landscape | Only if the iPad screen is genuinely designed for iPad |

Rules that apply to every frame (see also `STORE-LISTING.md`): app in use, not splash art; overlays such as an animated touch point are explicitly allowed [A, 2.3.3]; no third-party logos on the streamed desktop; no prices; 4+ content; no competing platforms (2.3.10).

Screenshot 6 is the honest fix for the biggest rating risk (a free user who wanted "anywhere"); do not move the paid tier out of the first eight frames.

### 4.2 App preview plan (15 to 30 s)

Apple's rules [A]: up to 30 seconds, up to three previews per language, autoplay muted in search results and on the product page, footage captured on device only ("Don't film people interacting with a device"), text overlays and narration allowed, no prices, no dated references, and a poster frame is required if autoplay is off. Sizes and codecs are in `STORE-LISTING.md` section 4.

| Time | Visual | Overlay |
|---|---|---|
| 0 to 3 s (the hook, and the only part many people see) | Live Mac desktop on the phone; pointer moves; one tap opens a file | Control your Mac from your phone |
| 3 to 9 s | Slide, tap, two-finger scroll; haptic icon pulses on click | Your whole screen is a trackpad |
| 9 to 14 s | Pinch zoom, view follows the pointer | Zoom follows your pointer |
| 14 to 19 s | Mic tap, words appear on the Mac | Talk instead of typing |
| 19 to 24 s | Wi-Fi to cellular route change, Remote Access header | Anywhere with Remote Access |
| 24 to 28 s | Scan, approve, end card with icon and name | No account. Nothing to set up |

Make the loop seamless (it autoplays and repeats), choose the poster frame from the hero moment (Mac desktop on the phone, big pointer), and localize the overlay text for French and Spanish only if those locales get their own previews. The route-change segment must be real footage (2.3.1).

### 4.3 Icon

- Crowding [M]: I sampled the icons of 21 competitors. Blue dominates the remote-desktop group (Jump Desktop, TeamViewer, RemotePC, RealVNC, plus blue accents on Windows App, RustDesk, DeskIn and Duet); near-black dominates the new Mac-remote crop (Remote, Mouse and Keyboard, Remote Mac Desktop Control, Happy, FullControl, Macky, Control, Rimote). Orange or red (Workbench, AnyDesk) and green (Splashtop, Remote Mouse) are taken; purple is lightly used (Screens 5). Avoid blue and black; a light or warm ground with one strong glyph will stand apart in a row of dark rounded squares.
- Build it as a layered icon in Apple's Icon Composer with light, dark and tinted variants [A: asset best practices]; it must read at App Store, Spotlight and Home Screen sizes. No text, no screenshot of a UI, one silhouette.
- Ship two alternate icons inside the 1.0 binary. Product page optimization tests can only use alternate icons that are already in the published binary [A]; without them an icon test needs a new app version.
- No cartoon, cow or comic imagery (The Far Side; see the launch checklist).
- Test after launch with Apple's product page optimization: up to three treatments of icon, screenshots and previews against the default page, up to 90 days, default page only [A]. At tens of impressions a day a test will not reach confidence; use it once traffic supports it, otherwise compare sequentially.

### 4.4 Ratings and reviews

Facts [A]: `RequestReviewAction` (SwiftUI, iOS 16 and later; the UIKit and older forms are `AppStore.requestReview(in:)` and the deprecated `SKStoreReviewController`) asks the system to show the prompt "if appropriate". If the person has not rated on that device it appears at most three times in 365 days; if they have, only for a new app version and after 365 days. Because it may show nothing, Apple says not to call it in response to a button tap. Guideline 5.6.1: do not "solicit, purchase, or incentivize positive App Store reviews" or ask users not to leave negative ones; asking repeatedly is also barred. Guideline 5.6.3 bars bots, servers or third-party services that inflate ratings, installs or engagement. Stars are shown per territory, and (per Apple developer-forum reports [I]) only after 5 ratings in that storefront.

Farside rules:

1. **Trigger** at the end of a session that has succeeded, not during it: the third completed session on at least two separate days, the session lasted at least 3 minutes, included at least one click gesture, ended by the person disconnecting or leaving the screen with no error, reconnect or dropped frames, and the person did not see the paywall in that session. Call the action once, from the disconnected-state screen after it has settled.
2. **Never** on first launch, on a pairing failure, on the Mac-not-installed gate, on the paywall, or within a session that used the Remote route and hit relay trouble.
3. **No sentiment gate.** Do not ask "Do you like Farside?" and route only happy users to the prompt; that is filtering by sentiment, the thing 5.6.1 describes. Offer a separate "Send feedback" row in Settings (email) for everyone.
4. **Persistent link:** a "Rate Farside" row in Settings that opens `https://apps.apple.com/app/id<APP_ID>?action=write-review` (the URL parameter is described in Apple's requesting-reviews documentation and works on iOS).
5. **Do not** email TestFlight testers or the waitlist asking for ratings, and do not ask for reviews on Product Hunt, Hacker News or Reddit.
6. **Reply** to every review inside 48 hours, lowest ratings first, with the fix or the workaround; Apple lets reviewers update their review after a reply. Do not reset the summary rating on updates.
7. **Root causes to remove before launch** (from rival reviews [I]): confusion about needing the Mac companion (send the Mac link by the share sheet from the first-run screen), surprise at a paywall (screenshot 6 and the contextual paywall wording), stuck Mac permissions, and slow or laggy video.

### 4.5 Pricing display effects

Competitor prices read from their App Store pages on 28 Sep 2026 [M] unless noted:

| App | Model and prices |
|---|---|
| Screens 5 | Free download; monthly US$3.99, yearly US$29.99 (a US$29.49 variant also lists), lifetime US$179.99 |
| Remote Mac Desktop Control | Free download; monthly US$7.99, annual US$47.99, lifetime US$99.99 |
| Astropad Workbench | Free tier capped at 20 to 30 minutes a day; US$10 a month or US$50 a year (AppleInsider, 8 Apr 2026) |
| Jump Desktop | Paid download US$14.99, plus Jump Desktop Connect US$4 per computer per month (per `COMPETITOR-LANDSCAPE-2026-09-28.md`) |
| Splashtop | Free download; Anywhere Access Pack US$5.99 a month, US$23.99 a year |
| Duet Display | Free download; Duet Air US$5.99 a month, US$49.99 a year |
| Happy (Codex and Claude Code) | Free download; Plus US$19.99 a month |
| Farside (D41, 30 Sep 2026) | Free download; CA$7.99 a month, CA$59.99 a year, 7-day trial on both |

What that means:

- A free download with "Offers In-App Purchases" removes the price barrier that a US$14.99 paid app (Jump) still has, which helps tap-to-download, velocity and the review base. The price then shows in the IAP list on the product page, so the name and price of each plan are part of the conversion story.
- CA$7.99 (about US$5.75) is just under Remote Mac Desktop Control's US$7.99 monthly. CA$59.99 (about US$43.19) sits between Screens 5 and Remote Mac Desktop Control yearly, and both are below Workbench.
- The yearly plan is a 37% discount on twelve months (CA$5.00 a month).
- Set the US prices explicitly instead of taking Apple's automatic conversion, so the IAP list reads cleanly in both storefronts. The exact US prices are an owner decision; equalization at 0.72 USD per CAD gives about US$5.75 and US$43.19.
- The trial is not visible in the product page IAP list; it shows in the paywall (StoreKit `SubscriptionStoreView`). Say "7 days free" in the promotional text and description, not in screenshots (2.3.7).
- RevenueCat's 2026 report says about half of paid conversions happen on day 0 and short trials convert worse than long ones (25.5% median under four days versus 42.5% for 17 to 32 days) [I]. A 7-day trial is standard; do not lengthen it for launch. Keep the billed amount the most prominent price on the paywall and any monthly equivalent secondary (Guideline 3.1.2(c)).

### 4.6 Custom product pages for three audiences

Apple: up to 70 custom pages per app; each has its own URL, screenshots, previews and promotional text; the metadata must be reviewed, but assigning keywords needs no review; keywords must come from your keyword field and each keyword combination must be unique to one page; results appear in App Analytics; deep links work on iOS 18 and later; Apple says developers see 2.5 percentage points more conversion on average (from 1.6%) when referring people to a custom page [A]. Create them after the app record and the first approved version exist.

| Page | Audience | Keywords assigned (from K1) | First three screenshot captions | Traffic sources | Deep link |
|---|---|---|---|---|---|
| `cpp-agents` | Developers running AI agents on a Mac | `agent`, `terminal` | 1 `Your agent stalled? Check it from anywhere.` 2 `See the terminal. Tap to answer the prompt.` 3 `Dictate the fix. It types on your Mac.` | Hacker News, r/ClaudeAI-style communities (check rules), X, Apple Ads test on "agent monitor" | Straight to pairing |
| `cpp-work` | Students and remote workers | `laptop`, `work` | 1 `Your Mac, after you leave the desk.` 2 `Finish it from the couch or the train.` 3 `Free on Wi-Fi. Anywhere with Remote Access.` | r/macapps-style communities, student and productivity newsletters, LinkedIn | Pairing, then paywall explainer |
| `cpp-home` | People who just need one thing from home | `home`, `file` | 1 `Forgot it at home? Grab it from your phone.` 2 `See it, open it, copy it.` 3 `Nothing to sign up for. Scan a code.` | Family and general Mac forums, website page for the query "control mac from iphone" | Pairing |

Honesty rule for `cpp-agents`: at launch there is no agent-specific feature. Describe the general capability truthfully (see the screen, tap, dictate a reply) and do not claim "take over your agent" or name any AI product until it ships (Guidelines 2.3.1, 2.3.7). Add "take-over" wording in the release that contains it.

Give every custom page a distinct URL when you post it, and use campaign links (`?pt=<provider token>&ct=<name>`, up to 30 characters) on the home page and in each post so App Analytics attributes impressions, page views and downloads per channel [A].

---

## 5. Launch plan

### 5.1 Timeline (aligned with `LAUNCH-CHECKLIST.md`: submit Tue 3 Nov, launch Tue 17 Nov)

| Date | ASO action |
|---|---|
| Fri 2 Oct | Name and trademark decision (checklist item D1). Nothing that needs the app record starts before this |
| Mon 5 to Fri 9 Oct | Create the app record; enter metadata drafts; sign up to Apple Ads Advanced (no cost until a campaign runs) and read the popularity score for the 73 keywords; **submit the Featuring Nomination** (5.5) |
| Tue 13 Oct | External TestFlight starts; use the public link for the waitlist, not for ratings (TestFlight builds cannot create App Store ratings) |
| Fri 30 Oct | Metadata, screenshots, preview, custom-page assets and localized copy final |
| Tue 3 Nov | Submit version, subscription group and both products together |
| About 4 to 10 Nov | Approval (Apple: about 90% of reviews finish in under 24 hours; first-time subscription apps can take longer). On approval, set release to a specific date and, if wanted, publish for pre-order (5.2) |
| Tue 10 Nov | Waitlist and press teasers; Apple Ads campaigns built and paused; campaign links and custom-page URLs generated |
| Mon 16 Nov | Confirm the store page resolves in both `/us/` and `/ca/` storefronts; release can take up to 24 hours to appear, so do not post until both resolve |
| **Tue 17 Nov** | Launch posts, Apple Ads on |
| 17 to 23 Nov | Launch week (5.3) |
| About 24 Nov to 1 Dec | First metadata iteration (v1.0.1) as part of the 30-day loop (section 6) |

### 5.2 Pre-orders: worth it?

Apple facts [A]: new apps can have a release date 2 to 180 days after the pre-order is published; the app must have been submitted **and approved by App Review** before you publish the pre-order; on release day the app downloads to pre-ordering devices with a notification; customers are not charged before release; free and paid apps are eligible but **subscriptions and in-app purchases cannot be pre-ordered**; Apple does not notify pre-order customers of date changes or removal; a pre-order counts toward conversion in App Analytics and is not counted again on download. Pre-orders also count as launch-day downloads for velocity [I] (Apple states the analytics rule; the ranking effect is heuristic).

Given your dates, approval will land around 4 to 10 Nov, so the pre-order window is only about 1 to 2 weeks, not the several weeks that make pre-orders powerful.

| For | Against |
|---|---|
| Zero extra work once the build is approved; gives every announcement a real store URL | The app is useless without the Mac companion, which is off-store; people who pre-order get an auto-download on launch day but no Mac app unless you email them |
| Pre-orders count as day-one downloads (velocity) [I] | Apple gives no contact list; you need your own waitlist to close the loop |
| Featuring Nominations have a type for "launch or pre-order" [A] | A rejection or slip compresses the window; Apple will not tell customers about a date change |
| Product page is live early for press and Product Hunt previews | Subscription cannot be pre-ordered, so no early revenue |

Recommendation: **yes, but only as a free by-product** of the approved 3 Nov build. Do not move the submission or the scope freeze for it. If approval is late, skip it and use the website waitlist as the pre-launch asset. If you can pull the first submission forward by two weeks (unlikely against the scope freeze on 16 Oct), pre-order becomes much more valuable.

### 5.3 Launch-week velocity

Industry consensus [I]: recent install velocity outweighs lifetime installs, and a new app gets a temporary uplift lasting days to weeks. It is not confirmed by Apple, so treat it as a reason to concentrate effort, not a formula.

- **Concentrate** every announcement in the same 48 hours (Tue 17 to Wed 18 Nov): Product Hunt, Show HN, Reddit, X, the waitlist email, press, and Apple Ads. Spread-out posts create a flat line, concentrated ones a peak.
- **Sequence** each visitor as store first, Mac companion second: send them to the App Store page (the custom page for their audience), and put "send the Mac download link to yourself" (share sheet or AirDrop) on the first-run screen. Measure **paired within 10 minutes** as the real activation event, not downloads.
- **Rules:** no purchased installs, no bots or "ASO growth" services (5.6.3), no review solicitation (5.6.1), no fake reviews or vote rings on any platform.
- **Apple Ads** are permitted and are the only paid source that also gives per-keyword data (5.4).

### 5.4 Apple Ads (Advanced) with under CA$100 a month

Apple facts [A]: Advanced is cost-per-tap with keyword, bid and placement control and no monthly cap; Basic is cost-per-install with no keyword or audience settings, search results only, and a US$10,000 monthly ceiling per app (Apple's own example shows US$500 a month). For each Advanced campaign the monthly spend will not exceed the daily budget times 30.4, and on some days spend can exceed the daily budget. Apple recommends separate brand, category, competitor and discovery campaigns, exact match with Search Match off for the non-discovery ones, and Search Match on in a discovery ad group to mine search terms. Canada is a supported country.

Benchmarks [I] (AppTweak Apple Ads benchmarks, 2025 data, ~50,000 campaigns): median CPT Canada US$1.17, US US$1.91, US Utilities US$1.23; Utilities tap-to-install conversion 63.2%, all-category median 56%; Utilities CPI US$2.25.

Setup:

| Item | Setting |
|---|---|
| Solution | Advanced (needed for keywords and search-term reports) |
| Storefronts | United States and Canada in one exact campaign; Canada costs about 40% less per tap [I] |
| Campaign 1: exact | Daily budget CA$2.29. Search Match off. Exact match only |
| Campaign 2: discovery | Daily budget CA$1.00. One ad group, Search Match on, no keywords. Move good search terms into Campaign 1 |
| Total | CA$3.29 a day, at most CA$100 a month (3.29 x 30.4) |
| Max CPT | Category keywords CA$1.60 to CA$2.00 to start (about the Canadian median at 1 US$ = about CA$1.39); brand keywords CA$0.60 |
| Ad creative | Default product page for the brand ad group; `cpp-agents` for the "agent monitor" test if you run it |
| Negative keywords | tv, roku, samsung, lg, sony, firestick, windows, android, vnc, rdp, gaming, vpn |

Exact-match keyword list (13):

| Group | Keywords |
|---|---|
| Brand | farside, farside mac, farside remote |
| Winnable category | control mac from iphone, remote control mac, mac remote, remote mac, trackpad for mac, mac trackpad, remote trackpad, remote mouse mac |
| Head, small bids | mac screen viewer, remote desktop mac |

Skip competitor-name keywords at this budget: a searcher who typed a rival's name has already chosen it, a zero-rating app converts poorly against that, and every tap must go to a term where Farside can win. (Guideline 2.3.7 is about store metadata, not ad keywords, so this is a budget choice, not a rule.) Skip Claude, Codex and Cursor terms until counsel has looked at them.

Expected outcome [R]: at Canada's median CPT about 60 taps a month; at the benchmark 56 to 63% tap-to-install about 35 installs (range 33 to 39). Free installs convert to paying at low single-digit percentages (RevenueCat 2026 puts Utilities near 2% download-to-paid at day 35, as summarised on the fetched page; verify) so expect about one subscriber from ads. The value is keyword data, a test of which custom page converts, and a little launch-week velocity.

Credit: Apple's promo-credit page says eligible developers get a one-time US$100 credit, converted to the account currency, if they are an App Store Connect account holder with at least one app available for sale on the App Store and they link the top-level account. The separate credit-eligibility page I fetched covered Apple Maps ads only, so confirm the App Store credit in the account before relying on it. If it applies, it funds most of the first month.

### 5.5 Getting featured

Facts [A]: Featuring Nominations live in App Store Connect (Featuring, then Nominations). Types: new content, app enhancement, app launch (launch or pre-order). Fields: name, type, description (purpose, priority, specifics), publish date or range, platforms, regions; optional related apps, localizations, attached in-app events, up to five supplemental URLs (docs, art, TestFlight links) and helpful details (accessibility, inclusivity). Roles allowed: Account Holder, Admin, App Manager, Marketing. Lead time: the App Store Connect page recommends a minimum of three weeks; the developer "Getting featured" page says at least two weeks and up to three months ahead for wider consideration. Nomination does not guarantee featuring. Apple's seven editorial criteria: user experience, UI design, innovation, uniqueness, accessibility, localization, and product page quality (including ratings).

Plan:

1. **File the launch nomination the week the app record exists (target Fri 9 Oct, 39 days ahead).** Type "App launch", publish date 17 Nov, platforms iPhone and iPad, regions US and Canada, supplemental links to the public TestFlight page, the website and the preview video. Describe what is new in one paragraph: a trackpad that uses the whole screen, click haptics, auto-follow zoom, on-device dictation, account-free QR pairing.
2. **Nominate the next release separately** (type "App enhancement") when the AI-agent features are dated, at least three weeks ahead.
3. **Score well on the criteria you control:** real French and Spanish localization (criterion 6), accessible native controls (be careful not to claim VoiceOver for the streamed canvas, as `STORE-LISTING.md` notes), a strong page with a preview, and platform features that editors like where they are honest and stable (App Intents and Shortcuts actions such as "Connect to my Mac", a Live Activity for an active session; Apple says App Intents becomes the Siri AI route in iOS 27 [I]).
4. **Expectation** [R]: a v1 utility with no ratings is a long shot for a Today card; treat featuring as upside and the nomination as free.
5. Be ready for the request for promotional artwork that Apple may email to Admin, App Manager and Marketing roles.

### 5.6 In-app events calendar

Facts [A]: up to 10 events published at a time and 15 approved in App Store Connect; each lasts up to 31 days and can be promoted up to 14 days before it starts; name 30 characters, short description 50, long description 120; events show on the product page, in search (event card for people who already have the app, screenshots for those who do not), and in editorial placements. Apple says events must be specific to an in-app experience and are not for price promotions without new content or general app-awareness promotions.

So the launch itself is not an event. A calendar built on real content:

| Window | Event (badge) | Requirement |
|---|---|---|
| 17 Nov to 14 Dec | None | Launch is awareness, which Apple says does not qualify |
| About 15 Dec to 14 Jan (announce from 1 Dec) | "Agent Take-over" (Major Update) | Only if the feature ships; deep link into it; also file an app-enhancement nomination |
| Feb 2027 | Second Major Update tied to the next shipped feature (for example Siri and Shortcuts actions or iPad multitasking) | Same rule |

Submit events at least two weeks before they start (heuristic; Apple only states the 14-day promotion window) and attach the approved event to the nomination.

### 5.7 How the website, Product Hunt, Hacker News, Reddit and X feed store rankings

There are four channels through which off-store activity can reach App Store search, from most to least reliable.

1. **Direct velocity and conversion [I].** Downloads referred from outside the store are counted (Apple names web referrers and app referrers as source types [A]). Concentrated launch traffic that converts on a clear page feeds the velocity and conversion signals. It only works if the click lands on a page that converts, hence custom-page URLs per channel and campaign links.
2. **Web search [A].** Apple says the description is used for web search results after release. Publish website pages for the same long-tail queries the store cannot serve ("control your Mac from your iPhone", "trackpad for Mac"), with truthful content, an App Store badge (Apple's badge rules: one per layout, do not alter, "Pre-order on the App Store" while in pre-order) and, once the App Store ID exists, a smart app banner. Every backlink from launch coverage helps those pages.
3. **Brand search.** People who hear "Farside" and type it in the store create the brand queries an Apple Ads brand ad group protects cheaply. The exact name "Farside" resolves to the space game first, so send people to the store URL, not to a search.
4. **Coverage.** Workbench's April 2026 launch was covered by MacRumors, 9to5Mac, AppleInsider, TechCrunch and MacStories [per `COMPETITOR-LANDSCAPE-2026-09-28.md`]. A short, accurate press note with the preview video and a TestFlight or App Store link is the realistic equivalent.

Channel notes:

| Channel | Rule or reality | Plan |
|---|---|---|
| Product Hunt | Launch time 12:01 am Pacific is best for makers planning ahead; personal accounts only; do not ask people directly to upvote; iOS installs convert poorly from PH because of the click, store, download, open path, so treat it as a web-traffic and credibility event first [I] | Personal maker account; first comment with the honest story; link the website (with both store and Mac download) rather than only the store |
| Hacker News | Show HN is for something people can try, ideally without sign-up; do not ask friends to upvote; be present in the thread | Fits the no-account pairing; state the two-download requirement plainly; link `cpp-agents` |
| Reddit | Rules differ per subreddit; I could not fetch r/macapps rules (blocked), so read each community's rules and any weekly self-promotion thread before posting | One authentic post per community, developer-flaired where required, no vote-asking, with the audience-specific custom-page link |
| X | Short native video from the preview; thread with the three differentiators; reply to the responses | Link campaign-tagged URLs |
| Newsletter and press | Pitch after the app is live in both storefronts | Send with the press kit from the website |

---

## 6. What to measure, and the 30-day loop

### 6.1 App Store Connect metrics [A]

| Metric | Definition | Read it as |
|---|---|---|
| Impressions | Times the app was viewed for more than one second on the Today, Games, Apps and Search tabs (includes product page views) | Search reach; unique-device version available |
| Product page views | Times the product page was viewed (including StoreKit loads) | Tap-through = page views / impressions |
| Conversion rate | Total downloads and pre-orders divided by unique-device impressions (pre-orders are not counted again at download) | Overall page and creative quality |
| First-time downloads, redownloads | Downloads on iOS, macOS, tvOS, visionOS | Growth |
| Source types | App Store Search, App Store Browse, App referrers, Web referrers, App Clips | Compare conversion by source; search is the intent signal |
| Custom product page and product page optimization views | Impressions, downloads, conversion, retention and proceeds per page | Which audience or creative wins |
| Campaign links | Impressions, page views, downloads, usage, sales and subscriptions per campaign token | Channel attribution |
| Monetization cohorts | Download to paid conversion, proceeds per download | Whether traffic pays |
| Peer group benchmarks | Your app versus apps with the same business model, category and download volume: 25th, 50th, 75th percentile of conversion rate, proceeds per paying user, crash rate and retention | Where you stand without guessing |
| Usage and crashes | Sessions, active devices, crashes | Stability; sessions require user opt-in |

Thresholds: most acquisition metrics appear once you have at least 5 first-time downloads or pre-orders, and usage metrics once you have 5 active devices. I found no per-query organic search report in the documentation I fetched (only source types), so use Apple Ads search terms for query data and a third-party rank tracker (AppTweak, Appfigures or MobileAction) for organic rank; verify in your account.

Reference conversion numbers to calibrate against [I]: Apple says the average default product page converts at 1.6% and a custom page adds about 2.5 points; AppTweak's 2025 US data gives 8.56% for product-page-view to download and 3.8% for impression to download across all categories. These use different definitions; trust your own peer-group benchmark over any of them.

### 6.2 Metrics to log daily for 30 days

Impressions, page views, downloads by source type, conversion by source, paired-within-10-minutes rate (only if the signaling service can count completed pairings without identifying anyone, which must be checked against `PRIVACY-POLICY.md`; otherwise use App Store Connect sessions and retention and add no client analytics), trial starts, paid conversions, crash-free sessions, ratings count and average by storefront, and organic rank for 15 tracked phrases in both storefronts: control mac from iphone, remote control mac, mac remote, remote mac, trackpad for mac, mac trackpad, remote trackpad, remote mouse mac, mac screen viewer, remote desktop mac, remote desktop, remote access, screen viewer, remote keyboard, and farside.

### 6.3 The 30-day iteration loop

| Days | Focus | Decision rules |
|---|---|---|
| 0 to 3 (17 to 20 Nov) | Health, not optimization. Watch crashes, pairing success, review text, tags in App Information, Apple Ads terms | Fix crashes and onboarding gaps first; remove misleading tags; reply to every review |
| 4 to 7 | Read the funnel: impressions to page views (tap-through) and page views to downloads, split Search versus Web referrer | If Search tap-through is low against your peer benchmark, the icon, title or first three screenshots are weak: queue an icon and screenshot test. If page-view conversion is low but tap-through is fine, the page is over-promising: fix screenshots 4 to 8, the description opening and the paywall messaging |
| 8 to 14 | First metadata change (submit v1.0.1 about 24 Nov, live about 1 Dec) | Only one variable: move the subtitle from A to A2 if "control" and "iPhone" tokens are not helping, or add K2 tokens if agent traffic shows up. Do not change more than one field at a time |
| 15 to 21 | Read ranks. Compare the 15 tracked phrases before and after; check en-CA versus en-US behaviour with the 3-token swap; review Apple Ads search terms and promote winners to exact | Keep, revert or extend. Add negatives for waste |
| 22 to 30 | Custom pages and events. Compare `cpp-agents`, `cpp-work`, `cpp-home` conversion and retention; decide whether a second event or feature nomination is justified | Retire the weakest page; double the budget on the strongest keyword only if paid conversion supports it |

Guard rails: one metadata change per storefront per 14 days so effects can be attributed; every change logged with date, field, old value, new value and the metric expected to move; a rank drop within 3 days of a change is treated as noise unless it persists past day 7.

---

## 7. Assumptions, gaps and things I could not verify

- **iTunes Search API is a proxy.** It over-weights title-text match and does not mirror in-store rank. All "open" and "locked" calls come from who appears in the top 10 and their rating counts, not from measured rank.
- **Autosuggest is coarse.** No keyword popularity scores were available; Apple's own score (5 to 100) is inside an Apple Ads Advanced account.
- **Canada indexing of en-US when an en-CA locale exists** is unverified; the test is in section 3.4.
- **IAP-name indexing and screenshot-text indexing** are unproven; treat any benefit as a bonus.
- **Subscription display-name limits:** Apple's IAP page says 30 and 45; the subscription page lists none; `SUBSCRIPTION-SETUP.md` says 35 and 55. All proposed strings fit the tighter figures.
- **Apple Ads credit** for App Store campaigns: confirm eligibility in the account.
- **Rating display threshold of 5 per storefront** comes from developer-forum reports, not an Apple doc.
- **Reddit rules** could not be fetched; read them per community.
- **FX:** figures use about CA$1.39 per US$1 (the rate implied by `SUBSCRIPTION-SETUP.md`); replace with the day's rate.
- **Trademark opinion pending:** if counsel changes the name, redo only section 3.1; the keyword design and the rest hold.
- **Method of the token-coverage score in 3.1** is my own simplification; Apple does not document how words in different fields combine.
- **Competitor facts** (ratings, prices, subtitles) are US storefront values read on 28 Sep 2026 and change daily; a few subtitles and prices came from page summaries rather than raw HTML and should be re-read before you quote them publicly.
- **Apple review of "Remote Desktop":** the phrase is generic and Microsoft has used it for years, but Apple's own product is "Apple Remote Desktop". Risk is low; keep Option B as the documented fallback.
- **Consistency with other docs:** `STORE-LISTING.md` still shows working defaults (title "Farside: Mac Remote", subtitle "Use your Mac from your phone", a legacy keyword string) and the IAP limit figures noted above; reconcile them to this file when you decide.

---

## Sources (all fetched 28 September 2026 unless a date is given)

Apple, primary:

- App Store search: https://developer.apple.com/app-store/search/
- Product page (name, subtitle, keywords, screenshots, description, promotional text): https://developer.apple.com/app-store/product-page/
- App Store Connect platform-version reference (keywords, description, promotional text): https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information
- App Store Connect app information (name and subtitle limits): https://developer.apple.com/help/app-store-connect/reference/app-information/app-information
- App Store localizations and per-country languages: https://developer.apple.com/help/app-store-connect/reference/app-store-localizations
- Custom product pages: https://developer.apple.com/app-store/custom-product-pages
- WWDC25 session 328, What's new in App Store Connect (tags, custom page keywords): https://developer.apple.com/videos/play/wwdc2025/328/
- Product page optimization: https://developer.apple.com/app-store/product-page-optimization/
- In-app events: https://developer.apple.com/app-store/in-app-events/
- Pre-orders: https://developer.apple.com/app-store/pre-orders/ and https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/publish-for-pre-order/
- Featuring nominations: https://developer.apple.com/help/app-store-connect/manage-featuring-nominations/nominate-your-app-for-featuring/ (news post 12 Nov 2024: https://developer.apple.com/news/?id=nx3eotat) and Getting featured: https://developer.apple.com/app-store/getting-featured/
- Ratings, reviews and responses: https://developer.apple.com/app-store/ratings-and-reviews/ ; StoreKit review requests: https://developer.apple.com/documentation/storekit/requestreviewaction and https://developer.apple.com/documentation/storekit/requesting-app-store-reviews
- App Review Guidelines (2.3, 3.1.2, 4.1, 5.2, 5.6): https://developer.apple.com/app-store/review/guidelines/
- Guidelines for using Apple trademarks (third parties): https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html ; App Store marketing guidelines: https://developer.apple.com/app-store/marketing/guidelines/
- App previews: https://developer.apple.com/app-store/app-previews/ ; asset best practices (fall 2026 creative assets): https://developer.apple.com/app-store/asset-best-practices/
- In-app purchase information (30 and 45 characters): https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information ; subscription information: https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/auto-renewable-subscription-information
- App Analytics metric definitions: https://developer.apple.com/help/app-store-connect-analytics/reference/metrics-definitions/ ; campaign links: https://developer.apple.com/help/app-store-connect-analytics/acquisition/campaign-links/ ; peer group benchmarks: https://developer.apple.com/help/app-store-connect-analytics/benchmarks/peer-group-benchmarks
- App Review turnaround: https://developer.apple.com/distribute/app-review/
- Apple Ads: Basic versus Advanced https://ads.apple.com/app-store/help/apple-ads-basic/0001-compare-apple-ads-solutions ; campaign structure https://ads.apple.com/app-store/best-practices/campaign-structure ; keywords https://ads.apple.com/app-store/best-practices/keywords ; budgets https://ads.apple.com/app-store/help/bids-and-budget/0016-manage-budgets ; promo credit https://ads.apple.com/app-store/help/billing/0032-apple-ads-promo-credit ; countries https://ads.apple.com/app-store/countries-and-regions
- Apple Machine Learning Research, Scaling Search Relevance (Feb 2026): https://machinelearning.apple.com/research/augmenting-app and https://arxiv.org/abs/2602.23234 ; 9to5Mac coverage 6 Mar 2026: https://9to5mac.com/2026/03/06/apple-ran-a-test-on-the-app-store-to-see-if-ai-could-improve-search-result-rankings/
- WWDC26 App Store guide: https://developer.apple.com/wwdc26/guides/app-store/ ; Apple Newsroom 8 Jun 2026: https://www.apple.com/newsroom/2026/06/apple-expands-app-store-capabilities-to-help-developers-grow-and-reach-new-users/

Industry, named (all [I]):

- AppTweak, ranking factors (updated 28 Jan 2026): https://www.apptweak.com/en/aso-blog/app-store-ranking-factors ; Apple Ads benchmarks (2025 data): https://www.apptweak.com/en/aso-blog/apple-ads-benchmarks ; conversion benchmarks: https://www.apptweak.com/en/aso-blog/average-app-conversion-rate-per-category
- SplitMetrics, ranking factors (1 Sep 2025): https://splitmetrics.com/blog/apple-app-store-ranking-factors/
- Phiture, ASO trends 2026: https://phiture.com/asostack/aso-trends-in-2026/ ; WWDC26 recap: https://phiture.com/blog/wwdc26-updates/
- MobileAction, cross-localization (15 Apr 2026): https://www.mobileaction.co/blog/app-store-cross-localization/ ; new creative assets (18 Aug 2026): https://www.mobileaction.co/blog/new-creative-assets-are-coming-to-the-app-store/
- aso.dev cross-localization: https://aso.dev/metadata/cross-localization/
- ConsultMyApp screenshot-indexing test: https://www.consultmyapp.com/blog/-is-apple-now-indexing-screenshot-titles-on-the-app-store
- Asodesk on IAP names (5 Apr 2019, updated 8 Sep 2020): https://asodesk.com/blog/do-in-app-purchases-affect-aso-for-app-store/
- RevenueCat, State of Subscription Apps 2026: https://www.revenuecat.com/state-of-subscription-apps and the Utilities cut https://www.revenuecat.com/state-of-subscription-apps-2026-utilities
- Product Hunt launch guide: https://www.producthunt.com/launch ; Show HN rules: https://news.ycombinator.com/showhn.html

Measured by me on 28 Sep 2026 [M]: iTunes Search API (`https://itunes.apple.com/search?term=...&entity=software&country=us|ca`, and `/lookup` for release dates and icons), App Store search hints (`https://search.itunes.apple.com/WebObjects/MZSearchHints.woa/wa/hints?clientApplication=Software&term=...` with the storefront header), and public `apps.apple.com` listings for Workbench, Jump Desktop, Screens 5, Remote Mac Desktop Control, RustDesk, TeamViewer, AnyDesk, Windows App, Splashtop, RemotePC, Remote Mouse, Remote, Mouse and Keyboard, Duet, FullControl, Macky, Control, Rimote, Happy and others. Raw outputs were kept in the session scratchpad, not in the repo; the endpoints and terms above reproduce them.


## Current useful-session funnel (2026-09-30)

Pairing or a connected session is a reachability milestone, not useful activation. Retain the unfamiliar-user install→first fresh authorized picture within 2 minutes target; separately record applied useful input, explicit user-confirmed read/edit/save outcome and later return/reconnect. Local consent counters are optional and never export automatically. See USEFUL-SESSION-ONBOARDING.md for source facts and remaining physical validation.
