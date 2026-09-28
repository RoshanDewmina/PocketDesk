# PocketDesk design inspiration, round 2

Researched 28 September 2026. Research only: no product file was modified. PRODUCT.md still owns scope; everything here is a proposal until Roshan accepts it and it lands there. The product name will change, so nothing below depends on it. `[Name]` marks where it goes.

Companion to `UX-AUDIT.md` in this folder. That document covers what is broken in the journey and the functional first-run flow. This one covers how the product should look, move, sound and read, and how the marketing site should be built. Where the two overlap (first run), this one layers design on top of the audit's flow and does not replace it.

## How to read this

| Tag | Meaning |
|---|---|
| [L] | Viewed live in a browser on 28 Sep 2026 (screenshots inspected, sometimes with computed styles read from the page) |
| [B] | Inspected locally in an installed app bundle (`/Applications/Wispr Flow.app`, v1.6.447) |
| [M] | Mobbin screen, flow or section viewed. Mobbin has no macOS catalogue, so Mac patterns use iOS analogues and web sections |
| [W] | Web page fetched. The fetch tool returns a model's summary of the page, not raw HTML, so text claims are paraphrase-level and were wrong at least once (see 2.1) |
| [S] | Web search snippet only, page not read |
| [D] | Apple documentation fetched through the context7 MCP |
| [I] | My inference or idea, not evidence |
| [U] | Unverified, needs a check before anyone relies on it |

Copy from other companies is paraphrased on purpose. UI labels of a few words are quoted only to identify a screen.

---

## 0. Summary

**Why the current apps read as plain.** From the redesign receipts, both apps are competent Apple-native shells: quiet home, immersive session, glass dock, standard controls, a faint Paperwash tint. They sit at the first three rungs of the ladder in 4.1.1 (tokens, materials). They have no signature idea, no motion language beyond system transitions, no sound, no illustration or voice, no teaching moment, and no personality in empty and error states. That is not a defect of native SwiftUI. Wispr Flow's desktop app is an Electron shell with a small Swift helper [B] and still feels premium, because someone designed every moment.

**The lane is open.** Astropad Workbench, the benchmark, has an excellent engine story and a clean but generic site: white canvas, crimson button, stock-looking device shots [L]. Jump Desktop and Screens are spec-led and utilitarian [W]. The two most interesting newcomers to "phone controls your Mac" are Perplexity's Personal Computer (cinematic, serif, glass, a setup checklist whose last step is pairing your phone) [L][M] and the ChatGPT app's remote access to Codex on a Mac [M]. Nobody in the category owns a distinctive brand device, a great first run, or a sound.

**Ten laws of premium extracted from Wispr Flow and the other references** (evidence in sections 2 and 3):

1. One ownable typographic voice. Wispr sets an old-style serif at display size, weight 400 only, with authority from scale [L].
2. A tiny palette with strict roles. One colour is reserved for primary actions and used nowhere else [L].
3. A brand device that shows the product idea in motion. Wispr's is spoken words riding a ribbon through a waveform pill and becoming text. Ours should be touch becoming pointer.
4. Show the transformation, do not describe it. Before and after, side by side, with the messy input visible.
5. Restraint in JavaScript. The whole Wispr home page runs six scroll triggers, one of them pinned [L]. Everything else is CSS and video.
6. Human craft marks: hand-drawn underline, ink-outlined sticker illustrations, a giant wordmark footer, an FAQ that looks like a chat [L][B].
7. Onboarding is the product demo. Just-in-time instructions, a low-stakes practice field, language that says how little is left, and a celebratory beat only at the aha moment [M][W].
8. Sound and state are iterated like code. Wispr's bundle holds 17 dated versions of its sound set, and the newest ones are the shortest [B].
9. The product keeps moving. Small, frequent, considerate releases, such as holding updates while you are working [W].
10. Speed is felt as premium. Reviews single out instant activation [W].

**Recommended next step.** Run four-artifact spikes on three directions, not ten: Direction 1 (Paperwash Pocket), Direction 9 (Aurora) and Direction 4 (Tether), then probably combine (see the end of section 7). The four artifacts are Home card, session dock, one Mac setup step and the site hero, so the directions are comparable side by side.

---

## 1. Where the category stands on design

| Product | What its design says | Evidence |
|---|---|---|
| Astropad Workbench | Confident, tidy, generic SaaS. A headline about accessing and controlling your AI agents from anywhere, a crimson pill button, press-logo row, three feature cards, a split section that puts a Mac mini next to a phone. Account sign-in then a Roku-style device list. 4.8 stars from 182 ratings; reviewers praise setup and resolution, complain that failures show no error message. Site shows $14.99/month or $79.99/year with a 20 minute daily free tier (fetched 28 Sep; the April press figure was $10 and $50, so verify) | [L] astropad.com/product/workbench, [W] App Store page and setup help |
| Jump Desktop | Enterprise and infrastructure tone, blob illustrations, device mockups, security badges | [W] jumpdesktop.com |
| Screens 5 | Friendly, feature-per-section, screenshots on light and dark variants, 7-day trial in the hero | [W] edovia.com/en/screens |
| Perplexity Personal Computer | Cinematic 3D nature renders, glass bubbles, serif headlines, product UI as translucent glass, a setup checklist with a phone-pairing step, an always-on section with a menu bar chip mockup | [L] perplexity.ai/personal-computer, [M] section links in the index |
| ChatGPT app remote access to Codex | Soft lavender gradient, a Mac glyph, a single black button that authorises the phone; a device list shows the Mac offline, when it was last seen, and a Reconnect link | [M] |
| Apple iPhone Mirroring and Continuity | The pair is always shown together; a pun as a section title; eleven capabilities in a fixed order ending with setting up from an iPhone | [W] apple.com/macos/continuity |

Takeaway: the open positions are a brand device, a first run that teaches, and a sensory identity (sound, haptics, motion). PocketDesk already has the best pairing model (QR plus explicit Mac approval, no account) and none of it is visible in the design.

---

## 2. Wispr Flow in depth

### 2.1 What was studied and how much to trust it

- The live marketing site, scrolled end to end at 1440 px wide, with computed styles and GSAP state read from the page [L].
- The installed desktop app bundle, v1.6.447: bundle identifier, assets, sounds, animation files [B]. I did not launch the app (it needs sign-in and microphone access), so I have not seen the Hub or Flow bar on screen. Their descriptions come from Wispr's help centre and Mobbin's iOS captures.
- Mobbin: 21-screen iOS onboarding, 11-screen account setup, 9-screen home, plus site sections [M].
- Wispr's own rebrand case study, its what's-new page, its help centre, and third-party teardowns [W].

Discrepancy worth knowing about: my first fetch of wisprflow.ai returned a summary claiming black text, white backgrounds and a blue accent. The live page is cream with lavender and teal. The rebrand page, two design-token extractors and the page's own CSS all agree with the live page. Treat any fetch-tool summary of colour or type as unreliable until measured; the values below are measured.

### 2.2 Brand system (measured on the live site unless marked)

| Element | Value | Note |
|---|---|---|
| Canvas | `#FFFFEB` (token name "Lumen") | Warm cream, not white |
| Ink | `#1A1A1A` | Text, borders, dark panels |
| Primary action fill | `#F0D7FF` lavender, text ink, 2 px ink border, 12 px radius (nav CTA 8 px) | Reserved for primary actions |
| Deep accent | `#034F46` forest teal ("Fathom") | Announcement bar, feature panel, FAQ questions |
| Warm accent | `#FFA946` ember ("Glow") | Highlights in illustration and active states |
| Wine accent | `#7F1C34` ("Pulse") | Defined as a token; appears sparingly [L token only] |
| Divider tan | `#E4E4D0` | Panels, borders |
| Display type | EB Garamond 400 and 400 italic, 96 px at hero, letter-spacing -0.03 em, line-height 0.95 | Second clause of the hero headline is italic |
| UI and body type | Figtree 400 to 700, 16 px body | Buttons 600 |
| Also loaded | JetBrains Mono, Monaspace Neon, Inter | Likely for developer sections [U] |
| Shape | Radii 12 px controls, 32 px cards, 40 to 80 px sections; pill nav | No shadows, flat fills with 2 px ink outlines [W from token extractors, consistent with screenshots] |
| Interaction | Button hover: transform 0.2 s, colour 0.3 s | Small, quick |
| Stack | Webflow, GSAP with ScrollTrigger (no smooth-scroll library), PostHog, GTM, Usercentrics consent banner | 6 ScrollTriggers: one pinned, one scrubbed with 1.5 s smoothing; eases expo and none |
| Page length | About 16,700 px tall at the test viewport, roughly 18 screens | |
| Illustration | Flat, ink-outlined sticker characters in coral, forest green, lavender-pink and cream; hand-drawn squiggle underlines; pointing hand; medals | [B] plus [L] |
| Rebrand story | Six weeks, a 2.5-person in-house team (design lead, illustration, web design, build). Concept name: Voice in Motion. Goal: emotional resonance, quiet luxury and editorial design instead of clinical AI-startup look. Tactile real-world photography over UI mockups. A sonic identity was described as in progress | [W] wisprflow.ai/rebrand |

### 2.3 Website, section by section [L]

| # | Section | What happens | Technique | What to steal |
|---|---|---|---|---|
| 0 | Announcement bar | Teal strip announcing the second product with a try-for-free link | Static | A slim strip for beta or release status |
| 1 | Floating pill nav | Cream pill with 2 px ink border; a Dictation / Notetaker toggle inside it; lavender CTA whose label names the visitor's platform | Sticky, rounded, no shadow | Pill nav with a Mac / iPhone toggle and a CTA that names the visitor's platform |
| 2 | Hero | Small eyebrow, giant serif headline of two clauses with the second in italic, one-sentence subhead, one button, a line naming the platforms. Below: spoken sentences run along a looping curved path. Older words are pale grey; current words are ink on a black ribbon that emerges from a waveform pill. A single word pops above the pill as if being typed. The photo-free hero is entirely typographic motion | SVG text on a path, animated. A third-party recreation calls it SVG plus a motion library [W]; the live page loads GSAP and no Framer Motion [L] | The single most transferable idea: a brand device that literally performs the product. Ours: touch trail becoming a pointer |
| 3 | Logo band | Black panel with big top radius and a marquee of company logos, sliding under the cream hero | CSS marquee | Big-radius panels as "chapters" that change the section's world |
| 4 | Comparison | Teal panel. Two cards side by side: keyboard at 45 words per minute, Flow at 220. The Flow card is a motion-blurred video of a person in motion with the text ribbon over it; the keyboard card is empty and frosted with a slow trickle of text. The contrast is communicated by emptiness, not a chart | Video, CSS | Compare by feel. "Time to first click" could be shown the same way once measured |
| 5 | How it works | Pinned scroll story. Left rail of three labels with a coral active tick. Centre: one phone-shaped video card that changes state per step. Right: a short heading and paragraph per step. A large pale looping path runs behind. The step-two state shows filler words highlighted in coral in a rambling dictation, then the clean sentence | A pinned ScrollTrigger whose scroll length is computed from the number of steps, plus a separately scrubbed trigger with 1.5 s smoothing [L] | A three-step pinned story: install on Mac, scan, control. One visual, three states |
| 6 | Feature list | Four features (languages, vocabulary, snippets, tone), each with a tiny live demo: flags cycling, a Formal / Casual / Very casual chip toggle changing a sample message | Small self-contained animations | Mini demos built from chips, not screenshots |
| 7 | Privacy | Pale tan panel, serif headline with an italic second line, three circular compliance badges | Static | A security section with only real, earned proof |
| 8 | Testimonials | Black panel. Quote cards in lavender, cream, orange, green and coral, each tilted, with photos or large stats, scattering as you scroll | Scroll-driven transform | Tilted card scatter once we have real quotes |
| 9 | FAQ | A two-column chat: a teal panel of questions on the left, cream answer bubbles with a tiny avatar on the right | Interactive list | FAQ as a conversation |
| 10 | Final call to action | Full-bleed blurred photograph, serif headline that puns on the two products, one button | Photo, blur | A cinematic closer |
| 11 | Footer | Two product cards; four columns of links (get started, professions, resources, company) including "compare", a changelog and a media kit; then a giant wordmark and the bar logo across the full width | Static | Giant wordmark, deep resource footer, changelog and media kit links |
| + | In the news | A hairline-ruled grid of press headlines with outlet logos | Static | Later, when there is press [M] |
| + | Pricing | Four tiers, monthly and annual toggle (20 percent off annually), a comparison table, an ROI calculator, a FAQ. Reported Pro $15 a month ($12 annual). Free tier reported as 2,000 words a week | [W], unverified numbers | Transparent pricing plus a calculator that turns time into money |

### 2.4 Copy tone (paraphrased)

Second person, short, warm, confident. Headlines pair a plain first clause with an italic second clause that lands the payoff. Subheads are one sentence. Feature copy names a human problem (rambling, pausing, changing your mind mid-sentence) rather than a spec. The FAQ answers in two or three sentences and links deeper. Humour is dry and rare. There is no hype vocabulary and no "AI era". Where they need proof they use raw numbers next to real people's names.

### 2.5 App onboarding, step by step

**iPhone [M][W]** (Mobbin onboarding flow, 21 screens, plus account setup, 11)

1. Dark splash with the waveform mark.
2. A set-up screen with the two words that matter in orange, a line promising it is quick, and one lavender button.
3. A multi-select of problems the user recognises (message backlog, email pile-up, wanting to type faster on the phone), then a how-did-you-hear-about-us question. This teaches the product's job before it asks for anything.
4. Sign in by email or provider. Language is pre-filled from the keyboard the user already has, with an Edit button.
5. Enabling the Flow keyboard. A dark tooltip sits directly above the iOS "Allow Full Access" switch and reassures about data (a serif statement that nothing said is stored). The next screen shows a picture of the iOS keyboard picker and tells you to tap and hold the globe key.
6. Practice on cards: a prompt to say anything, tap the check and watch it appear, then a prompt to dictate an email, with a grey placeholder script already in the field so nobody can fail. A strip inside the keyboard congratulates the first dictation.
7. A segmented progress bar at the top (two to four segments depending on the phase), a skip link on some screens, and language about being nearly done instead of a long meter.
8. Choose a default writing style, each option shown with a live example (Formal, Casual, very casual, Excited).
9. A closing screen inviting a quick test, with a lavender "Try Flow" button.
10. Home: a carousel of stat cards, gated so the first card says how many more words unlock the stats; tabs for features that are not yet unlocked show padlocks. A coach card invites the first real use in Notes or Messages.

A behavioural-science teardown of this flow [W, Kristen Berman] names eight mechanisms: problem-focused questions that build a mental model, just-in-time instruction, no skip on essential steps, a low-stakes practice sandbox, error-proofing with placeholder text, "almost done" language instead of long progress bars, personalisation as an effort investment, and a no-credit-card start that still filters for commitment. Note the tension: the teardown says setup cannot be skipped, while the Mobbin captures show a skip link on some practice screens. Both can be true (required steps versus optional practice).

**Mac [W]**

Drag to Applications, launch, and the icon appears in the menu bar. Sign in through the browser and the session hands itself back to the app. Grant microphone and Accessibility (plus a keyboard-monitoring privacy prompt on newer macOS). Answer a few setup questions (product intent, how you heard of it). Test the microphone with live rising bars. Pick a shortcut: push to talk or hands-free. Pick languages. Practice in a demo window where the text appears live. Everyday feedback is a small bar with moving white bars while you speak, holding Fn by default. Recent releases: a redesigned sign-in with full-motion slides (10 June 2026), a Flow bar you can drag to either screen edge (9 July), startup that no longer pops the window open (21 August), and updates that wait until you stop working (4 September) [W wisprflow.ai/whats-new].

### 2.6 Sensory and asset evidence from the installed bundle [B]

The app is an Electron shell (bundle id `com.electron.wispr-flow`) with a native Swift helper directory, 94 MB of assets. What it ships:

| Asset | Finding |
|---|---|
| Sounds | Seventeen dated sound-set folders (v1 through v12 with point releases such as v7.2, v8.2, v11.2, v11.3, v11.4), plus a notification family. Named sounds: dictation start, dictation stop, paste, a lock sound (file name popo-lock, purpose unverified), achievement, notification, and success, alert and error variants |
| Sound lengths | Latest set (v12): start 0.15 s, stop 0.28 s, paste 0.15 s, lock 0.29 s, notification 0.28 s. An older set (v11.4) had stop at 0.48 s and paste at 0.62 s. Achievement 1.45 s. Success 1.98 s, error 1.93 s, alert 0.97 s. Direction of travel: shorter and subtler with each iteration, with longer sounds kept for rare, meaningful outcomes |
| Animation | Two Lottie files (a celebration and a pulsing circle), four onboarding GIFs of the sticker characters (named ptt, popo, speak and whisper, 1.7 to 6.5 MB each), sign-in videos (five in the top folder plus Mac and Windows sets), a 42 KB waveform video |
| Illustration | About 34 items in the illustrations folder (flat stickers, a pointing hand used as a coach mark, a checklist-plus-speech-bubble icon, rank medals in two generations, use-case illustrations) and a separate folder of holiday-themed images |
| Type | EB Garamond, Figtree, Manrope, Google Sans Code |
| Gamification | Ranks and an achievement sound exist in the bundle; the Hub reportedly shows words per minute against other users and a daily streak heatmap [S] |

Two lessons. First, a product that feels alive ships sensory assets in versions and prunes them. Second, an Electron app bundling GIFs shows how low the bar for native apps can be raised: PocketDesk can do this with SwiftUI, Rive or transparent video at a fraction of the size.

### 2.7 Why it feels premium (distilled)

1. Type does the branding. A serif at 96 px, weight 400, tight tracking, with an italic clause. No icons or gradients are needed to look expensive.
2. Colour with jobs. Lavender means "press this". Teal means "a different chapter". Cream is home. Nothing else competes.
3. Flat and outlined, not glossy. Ink borders and flat fills give a tactile, printed feel with zero shadows. (Native apps get depth from Liquid Glass; content stays flat.)
4. The hero performs the product. You watch speech become text.
5. Proof by contrast (45 versus 220) and by transformation (rambling text cleaned live).
6. One pinned story rather than many scroll effects. Six triggers in total.
7. Tactile, real photography, blurred with motion, instead of laptop mockups.
8. Craft marks that only people make: squiggle underline, tilted cards, a chat-shaped FAQ, an oversized wordmark.
9. Onboarding that is a demo, with a practice field that cannot fail.
10. Sound and behaviour iterated over many versions; quiet startup; updates that wait.

### 2.8 What not to copy

Cloud-only processing and periodic window screenshots draw privacy criticism [S from review roundups]; PocketDesk's local-first, no-account pairing is a genuine advantage and the design should lead with it. Wispr's site loads consent tooling, analytics and session recording; a privacy-first product can skip all of that and turn "no banner" into a proof point. Mandatory sign-in and no-skip on essential setup suit a dictation tool but our pairing has no account; keep only the permission steps mandatory (and give an honest view-only fallback). The stat-gating and rank gamification suit a daily habit product; for a remote-access utility, reassurance stats (last seen, uptime) are more honest than points.

---

## 3. Other references

Two groups: marketing sites for Mac and iOS utilities, and in-app onboarding. Links are in the index (section 6).

### 3.1 Marketing sites

| Reference | What it does well | Steal | Evidence |
|---|---|---|---|
| **Raycast** | Near-black, huge whitespace, a plain hero with an interactive keyboard graphic, product UI floating in a red glow; long gaps between ideas so each lands. Sections: value line, extension tabs, AI, testimonials grid of recognisable faces, "what else" grid, community, developer platform | Slow pacing; product UI as the only imagery; a testimonial grid of named, credible people | [L] hero, [W] structure |
| **Linear** | Dense, credible product shots in tabbed sections; almost no animation; agents positioned as first-class | Density as trust; restraint | [W] |
| **Dia and Arc (The Browser Company)** | Dia's hero is warm yellow dappled light with a ghost serif wordmark and a laptop window; a pinned 01, 02, 03 feature list; a sticky download pill that appears at the bottom of the viewport. Arc's first run: the desktop dims, an orb grows into a window, staggered text arrives; a fun import step; the intro can be a transparent-background video inside a SwiftUI view | Ambient-light metaphor; sticky CTA pill; intro sequence | [L] Dia hero, [S] Arc onboarding; Dia 1.42.1 is installed locally [B] |
| **Things 3** | The app icon is the hero, a short "watch the intro" link, Apple Design Awards and press quotes carry persuasion | Let the icon and the awards do the selling; a one-minute intro video | [L] hero, [W] |
| **CleanShot X** | Headline tints the words "capture apps." in the brand blue; social proof (250,000+ users, 4.9 stars) and a 30-day guarantee up front; a bordered "How it works" video button beside the primary | One coloured phrase in the headline; risk reversal | [L] hero, [W] |
| **Screen Studio** | A glowing ring icon as the hero, a Product of the Year badge, a showcase made with its own product | Use our own product to make the demos (record the phone session with zoom and motion polish) | [L] hero, [W] |
| **Granola** | Warm greys with an olive button, one plain positioning line, and a consent dialog with a wink | Warm neutrals; small humour; define by what you avoid ("without a bot" maps to our "no account") | [L] hero, [W] |
| **Flighty** | Apple Design Award 2023. Hero: a phone held in a hand with floating notification chips around it. A sticky pill at the bottom acts as a chapter selector (before, at the airport, after landing). Light, then dark sections. Feature headlines state a benefit and end with a full stop | Chips orbiting a phone; a chapter pill; benefit headlines | [L] |
| **Perplexity Personal Computer** | The closest adjacent product. Cinematic 3D renders (a Mac mini on a mossy hill beside a glass bubble); serif headlines about setting up and running it; a translucent setup checklist card (download, install, allow permissions, connect, pair your phone); a menu bar chip mockup in an always-on section; four-card and six-card capability grids that include an iPhone remote | Checklist as storytelling; menu bar mockup; the phone-pairing step as the closer | [L] hero and sections, [M] |
| **Aqua Voice, Aside, Framer, Sketch, Craft, Spline** | Desktop-app hero patterns: headline, "Download for Mac", a window floating over soft colour; Aqua adds a footer with live system status | Footer status line; a floating-window hero that is not a flat screenshot | [M] |
| **Apple Continuity and iPhone Mirroring** | Phone and Mac shown as a pair in every shot; an "alone versus together" framing; a punny section title; setup with iPhone as the last item | Always show the pair; a playful pun once | [W] |
| **Tailscale** | Plain-spoken and calm: installation takes minutes, switching is easy; social proof as raw developer quotes about setup; blue accent | Raw quotes; matter-of-fact reassurance about networking | [W]; app 1.102.4 installed locally [B] |

### 3.2 In-app and onboarding

| Reference | Pattern | Use for us | Evidence |
|---|---|---|---|
| **Craft, interactive tutorial** | The instruction is itself the thing you manipulate (the task is to long-press and move the instruction card, or to swipe on it to change its style). Next stays disabled until done. Reset and Skip are visible | Our 20-second gesture coach | [M] |
| **My BMW, coach marks** | Step counter ("2 of 6"), a tutorial list you can revisit | Replayable "How to use" | [M] |
| **Superhuman** | Onboarding is a 30-minute concierge session that drills muscle memory with synthetic data and a challenge to keep your hands off the mouse | Practice on a fake desktop; badge each gesture | [W] |
| **Raycast** | First run centres on choosing your global hotkey; a "show onboarding" command replays it; permissions asked when a feature needs them | Replay from Settings; ask in context | [W] |
| **Arc** | Cinematic intro then delightful import with playful language | A three-second intro that sets the brand | [S] |
| **Flighty** | Alert preferences with PRO chips, a coach bubble, an empty state that invites the first action (add your next flight) | Our "no Mac yet" and "Mac napping" empty states | [M] |
| **Edits, Duolingo ABC, Monzo, Turo** | Permission priming: one Continue button, a friendly illustration, a plain reason. Edits uses three lines: how you'll use this, how we'll use this, how the setting works | Priming for Local Network and microphone | [M] |
| **Telegram, Binance, Brave, Mercedes-Benz** | QR scan screens: corner brackets or a rounded frame, torch and manual-code fallbacks | Our scanner | [M] |
| **Oura, Monese, Monzo, Tonal, IKEA Home** | "Searching nearby" screens with a pulsing or sweeping radar | The wait for Mac approval | [M] |
| **Dyson, Meta Quest, Wise, Monarch, PlayStation** | Pairing-success screens with a check, a confetti moment or a bold poster | One restrained success beat | [M] |
| **Cleo, Plum, Chime, Lloyds, Tabby** | Setup checklists with progress rings and ticks | The Mac permission checklist | [M] |
| **ChatGPT app (Codex remote), Xbox** | Authorize this phone on the computer; a code-entry screen; "turn on remote features" with icon rows that explain what you get | The Mac-side approval that names the phone; priming with icon rows | [M] |
| **SmartThings, Google TV, Xbox, Grok Bot** | Touchpad-style remote surfaces; Grok Bot's remote desktop view has a trackpad mode and recenter pointer in a glass menu | Trackpad affordance and a plain "recenter pointer" action | [M] |
| **timespent (paywall)** | A hand-signed founder note that promises no dark patterns, three circular price badges | Tone for pricing if we charge | [M] |
| **Apple Design Awards 2026** | Winners named for interaction and visuals: Moonlitt (Interaction: easy onboarding and Liquid Glass done well), Tide Guide (Visuals: custom animations, sky-matching palette on top of glass), grug (Delight and Fun). Finalists include Panic's Blippo+ and (Not Boring) Camera | Identity sits on top of glass, not instead of it | [W] |

### 3.3 Mobbin pattern library grouped by first-run beat

These are the links to open when designing. Screens are grouped by the moment in our flow they inform.

| Beat | Screens |
|---|---|
| Welcome and setup tone | [Wispr setup intro flow](https://mobbin.com/flows/8e8615c6-73d9-4b05-933e-275401ccb16a), [Wispr test-the-magic screen](https://mobbin.com/screens/2fbbea07-8d50-497d-9847-da88f336f8e4), [Wispr account setup flow](https://mobbin.com/flows/fe6c2752-5959-48e3-9398-643b7980c27e) |
| Permission priming | [Edits](https://mobbin.com/screens/4bce154c-bc90-4b02-87ab-02dc3b0fe523), [Duolingo ABC](https://mobbin.com/screens/5ac02ec1-67f7-4297-ba40-53d95c97e9a0), [Monzo](https://mobbin.com/screens/0ec67602-50b0-45a0-8b4e-598fca2906d6), [Turo](https://mobbin.com/screens/64b7b165-5876-45f1-ba60-02a665c1f123), [Wispr data reassurance beside the system toggle](https://mobbin.com/screens/d24ba239-fb9f-450d-9cfd-3c68b41ff9cd), [Xbox remote features](https://mobbin.com/screens/483accd2-773e-42fb-90d0-8eabd14d7679) |
| QR scan | [Telegram](https://mobbin.com/screens/0444d454-4fcc-49cf-b07d-296a6af86b77), [Binance](https://mobbin.com/screens/ff3a65b3-76eb-4621-be12-f10e1ad8e5cb), [Mercedes-Benz](https://mobbin.com/screens/fbf631d7-b45d-41e2-ba57-de99ced9e96f), [Brave](https://mobbin.com/screens/f78f212b-8641-4431-835b-314ec4dae5f4), [Alexa](https://mobbin.com/screens/7c95dd6a-5e7d-4415-9da2-7c7b38307d28), [Canva remote QR](https://mobbin.com/screens/968be409-0199-4ec1-80a0-9f82cef1e896) |
| Approve on the computer | [ChatGPT: authorise this phone for Codex on your computer](https://mobbin.com/screens/235eefa5-d05e-4fc9-8086-30b2964b5993), [Xbox enter code](https://mobbin.com/screens/c9044a6e-4b2c-4a94-b198-44933abb06ea) |
| Waiting and searching | [Oura locate](https://mobbin.com/screens/6aecd472-fed1-4c15-a0d3-e127a01a1ae9), [Monese finding nearby](https://mobbin.com/screens/b4727421-8071-4ac3-9dee-78ee2c56841a), [Monzo searching](https://mobbin.com/screens/55f5b99d-ad81-4903-a960-40c3edfb9b50), [IKEA connecting to hub](https://mobbin.com/screens/889e8972-4408-4123-905b-d035539ebcc4), [Tonal searching](https://mobbin.com/screens/e1c04d07-892d-4cca-94ea-cc80b8d5cbe8), [Starling looking nearby](https://mobbin.com/screens/c694f3ef-be19-4920-b01a-6b8fc4621fb4) |
| Paired and success | [Meta Quest](https://mobbin.com/screens/58ee0006-1862-45ad-9b3b-4865f168fd5c), [Dyson](https://mobbin.com/screens/ce32ad1c-f991-4cee-a6f5-e61ced0a0e18), [Wise](https://mobbin.com/screens/7e895019-4335-410a-9fca-06038e8b73b4), [Monarch](https://mobbin.com/screens/78b9ebb4-1828-4d06-a440-803b38f8f368), [PlayStation](https://mobbin.com/screens/e5aa7075-d2ba-427a-a76b-57566e309101), [Meta AI](https://mobbin.com/screens/db7f3c2e-417f-48a7-a57a-58c29192d896), [LARQ](https://mobbin.com/screens/cd65c211-655c-43d5-be8a-029fd896b994), [Paired](https://mobbin.com/screens/b3a457f0-79eb-4831-8640-69d221443987) |
| Interactive tutorial and coach marks | [Craft browsing tutorial flow](https://mobbin.com/flows/261e0d10-aa8e-4396-af24-3bae256990de), [Craft get started flow](https://mobbin.com/flows/2d73c8ed-64a5-409f-b368-0ce4e52d3ae9), [My BMW tutorial flow](https://mobbin.com/flows/c329076f-a46e-4ec7-9078-eda8f57a4e82), [Wispr practice: say anything](https://mobbin.com/screens/4f7aee71-c448-4d17-bd2d-c2abbd1e6101), [Wispr practice: dictate an email](https://mobbin.com/screens/c6df8e4f-19a9-40ec-a413-da13d00d2cbd), [Wispr keyboard picker instruction](https://mobbin.com/screens/8d8c71ca-2463-4a83-abbb-0ef29d1db6b4) |
| Setup checklist | [Plum](https://mobbin.com/screens/bdf284fa-4681-4835-94b8-e7792e6ca25d), [Cleo](https://mobbin.com/screens/bae4115d-f0c5-457a-bc4b-4d9abf0a6276), [Chime](https://mobbin.com/screens/5964d1f6-e082-4612-a968-568b09e2cc8a), [Lloyds](https://mobbin.com/screens/82e6ae99-166c-4886-956b-c3dd8a6b9e56), [Peloton](https://mobbin.com/screens/5211f64d-c719-46b1-a1c2-2762992d794d), [Tabby](https://mobbin.com/screens/bf8f9b4b-f569-4e13-b743-568992ec3a7d) |
| Personalisation | [Wispr default style](https://mobbin.com/screens/7a56d7ca-da5f-4df5-b52e-61db8ee4801b), [Wispr style casual](https://mobbin.com/screens/4fb424b8-11cb-4c5a-9125-af99367dfecc), [Wispr style excited](https://mobbin.com/screens/c120376a-db4b-46e7-9f85-df74065c3784) |
| Device list and Mac offline state | [ChatGPT Mac offline, last seen, Reconnect](https://mobbin.com/screens/635cf9e7-fad6-4e72-b13d-20c138e4af00), [Roku connect your device](https://mobbin.com/screens/078311ac-cb2b-4d3c-9863-0a43aef1d089), [Alexa devices](https://mobbin.com/screens/a41f1f8c-fec6-4ca0-a6f2-a71a4b1e9141), [Fitbit connected devices](https://mobbin.com/screens/c95f7163-6cb8-4a26-9110-153977943fe7), [Quo connection quality](https://mobbin.com/screens/0a290bb8-a09e-4569-a5e6-d82ba3f1421d) |
| Touch-surface remotes | [Google TV](https://mobbin.com/screens/02830e97-4a4d-4317-b86b-30643215852a), [SmartThings](https://mobbin.com/screens/54345414-2c0d-4376-8335-7a65a69df97f), [Xbox](https://mobbin.com/screens/f29dc23d-69a0-4f4f-8914-fc4f6e2a4806), [Grok Bot trackpad mode](https://mobbin.com/screens/675e9d35-b189-4efc-a8af-b02b91ff2205), [Grok Bot with recenter](https://mobbin.com/screens/d7cf2b96-c651-4200-aa17-b3808b10eda8), [Brink](https://mobbin.com/screens/950daf53-8198-4460-a7a2-0402fe048e8e), [Tesla controls](https://mobbin.com/screens/4192225f-7091-4300-95e6-d9cf953072e1) |
| Full-screen live view with floating controls | [WhatsApp call](https://mobbin.com/screens/05583d8e-4d1f-4a09-82ce-54bb4a918089), [Apple Store video](https://mobbin.com/screens/ccb204fc-a636-4d88-9910-760f8a16bac1), [OpenPhone slide-up menu hint](https://mobbin.com/screens/5e78114d-4412-4439-902b-4955a5f95c8c), [Tolan pill](https://mobbin.com/screens/8b570236-6c4f-4fe4-8424-e7984d913a6f), [Sesame](https://mobbin.com/screens/8d4928c6-5268-4eed-8226-7bb10d79ea6f), [Grok connecting](https://mobbin.com/screens/52ab3bee-9310-4c1a-af50-7bce9d84de3e) |
| Flighty (iOS 26 glass bar, coach bubble, empty state) | [Onboarding flow](https://mobbin.com/flows/fbdbcea2-e12f-47b7-96f0-9bbbd87a3562), [Second onboarding flow](https://mobbin.com/flows/d6eb2eaa-bcca-47ce-ad5e-e46f314e1d9b), [Alerts](https://mobbin.com/screens/8c0d0134-0cff-4f0e-a898-438385cfd417) |
| Paywall tone | [timespent](https://mobbin.com/screens/b00fa672-0e18-4d18-8040-8912c0af8ca7), [Sunlitt](https://mobbin.com/screens/1be71829-fa39-4b78-a3c9-c2726c2ef26f), [Liven](https://mobbin.com/screens/a612cffd-939d-471f-9b89-bf734058ab1a) |
| Website sections | [Perplexity Personal Computer: mossy-hill hero](https://mobbin.com/sites/sections/4389591f-8844-4978-9946-2aa4fe1f517f), [checklist](https://mobbin.com/sites/sections/827da229-a516-4e10-86f8-44684d074eb5), [always-on menu bar chip](https://mobbin.com/sites/sections/5fbb4019-adc0-4d45-a92f-25513f0ccc38), [four cards](https://mobbin.com/sites/sections/20282fed-8582-40a2-aa6f-ec81fadb5507), [capabilities](https://mobbin.com/sites/sections/9972fd88-1601-41e7-95bf-8f46e1eccde3), [download it on any Mac](https://mobbin.com/sites/sections/9a743442-ac8c-4d76-9ed5-dd673fed4b04), [Aqua footer and hero](https://mobbin.com/sites/sections/03f083e3-7838-429b-8800-3d25fad9310b), [Aside closer](https://mobbin.com/sites/sections/d0219802-b9cd-4672-a63a-679ef733dcff), [Wispr giant-wordmark footer](https://mobbin.com/sites/sections/d2b17651-2709-4db5-99f2-d14af9dd09b2), [Wispr value cards](https://mobbin.com/sites/sections/57b66fab-f7e0-4ea1-bec6-9f6ad9b91a59), [Wispr in the news](https://mobbin.com/sites/sections/a9791d53-05c3-49c0-8f0f-8c4b459efe8f), [chat-style FAQ (Navigate)](https://mobbin.com/sites/sections/383b268d-e001-4ea7-8e52-d861849c4680), [editorial FAQ (Fiasco)](https://mobbin.com/sites/sections/2de9e891-6d2b-4142-a089-d499cfd54521) |

---

## 4. Distilled: stealable patterns

### 4.1 The app's visual identity

#### 4.1.1 Plain to premium: a ladder

| Rung | What it adds | Where PocketDesk is |
|---|---|---|
| 0. System defaults | Standard controls, grey panels | Host settings panels, parts of Home |
| 1. Tokens | One accent, real type scale, spacing, a designed dark mode | Partly (faint Paperwash tint) |
| 2. Materials and depth | Liquid Glass in the control layer, flat content | Yes: session dock. Confirmed direction in PRODUCT |
| 3. Motion language | Named springs, a few signature transitions, shared-element moves between states | Not yet |
| 4. Sensory | A haptic map, a sound palette, both tied to the same events | Click haptics only |
| 5. Identity | Icon, brand device, illustration, voice, designed empty and error states | Not yet |
| 6. Alive | Presence, seasonal touches, replayable tour, what's new, small easter eggs | Not yet |

The work for this round is rungs 3 to 5. Rung 2 is already right and should stay confined to controls.

#### 4.1.2 The nine decisions every direction must make

| Decision | Options and the evidence behind them |
|---|---|
| 1. Signature device | Wispr: spoken text on a ribbon. Flighty: notification chips. Things and Screen Studio: the icon itself. Perplexity: a glass bubble. Ours (proposals): a tether from thumb to pointer, a pointer character, or a living gradient that shows connection state [I] |
| 2. Display type | Serif at large sizes is the 2026 premium signal (Wispr, Dia, Perplexity, Aqua-style sites) [L][M]. Native path with no licensing: the system serif (New York) via `fontDesign(.serif)`, or `fontWidth(.expanded)` for a confident grotesk. `Font.Width` is iOS 16+ and macOS 13+ [D]; `fontDesign(_:)` is documented but I did not check its availability line [U]. Bundled fonts remain possible |
| 3. Colour | One action colour with a strict role; two or three surface tones; state colours for connected, waiting, attention. Warm neutrals feel less clinical than white (Wispr, Granola, Paperwash) |
| 4. Materials | Liquid Glass only above content: `glassEffect(_:in:)`, group nearby glass in a `GlassEffectContainer`, morph between states with `glassEffectID(_:in:)`, `.interactive()` for touchable glass [D]. Never glass on glass. Reported iOS 27 retune: a user slider between clearer and more tinted glass, less default transparency, darker edges [W, secondary sources, U on details]. Design so the UI is legible at both slider extremes |
| 5. Motion | A small vocabulary of named animations (4.1.3). `PhaseAnimator` for looping phases, `KeyframeAnimator` for authored sequences, `symbolEffect` for icon feedback, `contentTransition(.numericText)` for latency readouts, `MeshGradient` for ambient colour (iOS 18 and macOS 15 or later) [D for MeshGradient and PhaseAnimator; others from Apple docs knowledge, verify names before coding] |
| 6. Haptics | Tie each to one event and one visual (4.1.4). `sensoryFeedback` covers start, stop, selection, alignment, level change, success, warning, error and impact with weight or flexibility [D]. iPad has no Taptic Engine, so on iPad sound and visuals must carry the moment [U, verify] |
| 7. Sound | A small palette, each sound short (4.1.5). Wispr's own data: start 150 ms, stop 280 ms, rare success under 2 s [B] |
| 8. Icon and illustration | Layered app icon (Apple's iOS 27 icon retune is reported [W, U]), a menu bar glyph with state variants, one illustration style with a fixed outline weight and 4 or 5 fills. Ink-outline stickers (Wispr) or geometric flat shapes both work; consistency matters more than style |
| 9. Voice | Second person, short, calm, specific. Empty and error states get the most personality because they are where a product shows character |

#### 4.1.3 Motion spec starter [I]

Named tokens so every screen speaks the same language. Values are starting points to tune on device, not evidence.

| Token | Use | Feel |
|---|---|---|
| `settle` | Cards, sheets, dock open and close | Spring, response 0.45 s, damping 0.85; no overshoot |
| `snap` | Toggles, ticks, selection | Spring, response 0.25 s, damping 0.9 |
| `arrive` | First frame, pointer first appearance, success | Spring, response 0.6 s, damping 0.7; a single small overshoot |
| `breathe` | Ambient gradient, waiting pulse | 6 to 8 s ease-in-out loop, low amplitude |
| `draw` | Underlines, the tether line, checkmarks | Path trim over 0.35 to 0.6 s, ease-out |
| `drift` | Marketing parallax | Slow, scroll-linked, never faster than the scroll |

Rules: Reduce Motion replaces every loop with a static state and every spring with a fade; no motion may delay input; the streamed picture is never animated or blurred except briefly for privacy shielding.

#### 4.1.4 Haptic map [I]

| Event | Feedback | Visual and sound partner |
|---|---|---|
| Camera locks onto the QR code | Selection | Scanner corners snap to the code |
| Pairing accepted | Success | Sonar resolves into the Mac card; chime |
| Tap accepted as click (already built) | Light impact | Ripple at the pointer |
| Right-click, hold to drag begins | Medium impact | Pointer scales 1.15 with a brief halo |
| Drag drops | Alignment | Settle-halo where the pointer stopped |
| Pointer reaches a screen edge | Alignment or a soft rigid tick | Edge glow |
| Zoom crosses a preset level | Level change | Zoom label ticks |
| Coach beat completed | Selection | Check draws; tick sound |
| Connection lost | Warning | Chip changes; soft low tone |
| End session | Stop | Fade to Home |

#### 4.1.5 Sound palette [I, informed by [B]]

| Event | Length | Character |
|---|---|---|
| Phone connected (played on the Mac, and quietly on the phone) | 150 to 300 ms | Rising two-note interval, soft |
| Phone disconnected | 200 to 300 ms | The same interval falling, quieter |
| Pairing approved | Under 1 s | Slightly fuller version of connected; the only "reward" sound |
| Coach tick | Under 150 ms | Dry, wooden or glass tap |
| Warning or error | 300 to 800 ms | Low, round, not harsh |

Playing the connection sound on the Mac is doubly useful: it is delight and also a security signal that someone has just connected. Respect the silent switch on the phone; give the Mac sounds one setting in the menu. Version the sounds like Wispr does and prune them.

#### 4.1.6 Mac companion [I, informed by Perplexity's chip mockup and the audit]

- Menu bar glyph with three states (idle, waiting for approval, connected) and a single small animation when a phone connects. A real menu rather than a popover, as the audit recommends [D: HIG menu bar extras, via the audit]. SwiftUI's `MenuBarExtra` has menu and window styles; window style is macOS 13 or later [D].
- The setup window is a product surface, not a preferences pane: a checklist that updates itself, a live thumbnail proving Screen Recording works, and the pairing card with a soft pulse. Replace the one-time window with the menu after setup.
- "Your phone is here" confirmation on the Mac: a slim toast that names the device and offers Disconnect. Wispr's craft in the Mac app shows in what it leaves out: quiet startup, updates that wait.

#### 4.1.7 Delight inventory

Twelve moments, at most three of which should be celebratory in the first minute.

1. The Mac's menu bar icon blinks once and plays the connect tone when the phone connects.
2. The first frame unfurls from the Mac card into the full session.
3. The pointer arrives with a settle-halo the first time.
4. First click sends a small ripple at the pointer.
5. Empty state for "no Mac yet" with a friendly illustration; "Mac is napping" with a sleeping variant and honest wake guidance.
6. "Last seen" on Home, with presence dots (already an audit item).
7. Coach beats that tick with a haptic and a tiny sound.
8. A Live Activity on the Lock Screen and Dynamic Island for an active session, as Flighty does for flights [I, U: check what is allowed while backgrounded, since the session ends when the app backgrounds].
9. Shake or three-finger tap to find the pointer, echoing the macOS shake-to-find behaviour [I].
10. Alternate app icons and matching menu bar glyphs.
11. A what's-new card after updates and a link to a changelog.
12. Small seasonal touches, as Wispr's bundle shows [B].

#### 4.1.8 Guardrails

- Shader effects (`colorEffect`, `layerEffect`, `distortionEffect`) do not render UIKit or AppKit backed views [D]. Apply them to SwiftUI chrome only, never the streamed video or the touch surface.
- Keep the streamed picture sharp; the PRODUCT direction already says not to blur the desktop.
- Test with Reduce Transparency, Increase Contrast, Reduce Motion and the largest Dynamic Type.
- Confirm SDK 27 symbols against deployment targets before adopting them (per AGENTS.md).
- Xcode 27 no longer honours the compatibility key that kept pre-glass styling, so glass on standard controls is effectively automatic; adopting custom glass is a deliberate choice per control [W ecorpit, U].
- Sound and haptic work needs a physical device. Simulator evidence does not count.

### 4.2 The first-run experience, storyboarded

Layered on the audit's target flow (`UX-AUDIT.md` 2.1 to 2.5). The audit's HIG constraints stay: pre-alert screens have one Continue button, never show the system alert, and the gesture coach is interactive, brief, skippable, not repeated and replayable. Total target: about four minutes including two System Settings toggles, of which the pointer coach is 20 seconds and runs during the "approve on your Mac" wait so it costs no extra time.

| # | Where | Screen and motion | Sound and haptic | Copy (draft) | Pattern source |
|---|---|---|---|---|---|
| M1 | Mac, first launch | A 2.5 second intro: the desktop dims, the mark blooms, the headline arrives word by word. One button | Optional single soft tone | Headline: your Mac, in your pocket. Button: Get started | Arc intro [S]; Wispr's quick-and-short setup intro [M] |
| M2 | Mac, setup window | A checklist of three rows: Screen Recording, Mouse and keyboard, Open at login. Each row: icon, one plain reason, Allow. After Allow, a looping mini-illustration of the System Settings switch with a pointing hand while waiting. The row updates itself the moment access is granted: spring tick. When Screen Recording works, a live thumbnail of the display appears | Tick per row; a bigger tone when all rows are green | "One more, then you're in." Thumbnail caption: this is what your iPhone will see. Honest skip for Mouse and keyboard: use view only | Perplexity checklist [M]; Plum ring [M]; audit 2.3; Wispr point-hand [B] |
| M3 | Mac, pair | A big QR card with a slow sonar ring, "Send to iPhone" and an App Store QR beside it for a phone without the app | None until scanned | Scan with your iPhone, or send it | Audit 2.5 A and B |
| M4 | Mac, approval | The card flips to a native approval that names the phone and model. Allow and Not now | Success tone on Allow | "Roshan's iPhone wants to control this Mac." | ChatGPT Codex authorize [M] |
| M5 | Mac, done | The window folds toward the menu bar icon; the icon blinks once; a toast confirms | Connect tone (this doubles as the security signal) | "You're connected. I'll be up here." | Perplexity menu bar chip [M] |
| P1 | Phone, first launch | Two-second brand moment, then one screen: the promise, a Set up button, and "Already running on your Mac? Scan" | None | Your Mac, wherever you are. | Wispr setup intro [M] |
| P2 | Phone, scan | Camera opens on tap; corner brackets fade in and snap to the code | Selection haptic on lock, success on parse | "Point at the code on your Mac." Manual code link below | Telegram, Binance [M] |
| P3 | Phone, waiting for approval | A sonar pulse from a small Mac glyph (`breathe`). Below it, the practice pad appears with "while you wait, learn the trick". This is the coach starting inside the wait | None | "Waiting for your Mac to say yes." | Oura, Monese radar [M]; audit 2.4 |
| P4 | Phone, connected | The sonar resolves; the Mac card grows to full-bleed; the first frame arrives; the pointer arrives with a halo (`arrive`) | Success haptic, soft chime | (no text) | Original |
| P5 | Phone, coach | Five beats from the audit: move, click, scroll, pinch, controls. Each shows a two-second ghost finger; the instruction text sits inside the thing you manipulate; success draws a check and auto-advances; five dots for progress; Skip always visible; idle for six seconds shows a hint. Reduce Motion: static illustrations | Selection haptic and tick per beat | "Slide one finger. The pointer follows; it doesn't jump." Then "That's the whole trick." | Craft [M]; Superhuman rehearsal [W]; audit 2.4 |
| P6 | Phone, home | "Your Mac" card with a live thumbnail, status dot, last seen and a Connect button | None | (Mac name) is here. | Audit 3.5; ChatGPT device list [M] |
| P7 | Phone, optional | One question: how will you use this most (agents and coding, files and documents, presenting, helping family). Sets default sensitivity and which shortcut bar shows; plus a live sensitivity slider | None | "Pick a starting feel. You can change it later." | Wispr style choice and problem question [M][W] |

Rules for the flow:

- Three celebratory beats at most in the first minute: connect tone, first-frame arrival, "that's the whole trick". No confetti.
- Progress copy is "one more" language, not a long meter.
- Failure moments are designed too: Mac asleep, permission revoked, phone offline. Each says what happened and what to do next, in the same voice.
- Everything is replayable from Settings; the first run never repeats.
- Measure time to first successful click with a stopwatch on three new users before trusting any of this (audit section 8).

### 4.3 The marketing website

#### 4.3.1 Tone and copy rules

- Two-clause headlines: a plain first clause, a payoff in the second. One italic or coloured phrase per headline.
- Lead with the anxious questions: is it safe, does it work when I am away, will my Mac be awake. Answer them with specifics, not adjectives.
- Prove only what we have measured. PRODUCT says no comparative performance win is established. Until it is, do not print latency or "faster than" claims.
- Avoid category clichés ("for the AI era", "seamless", "blazing"). Show, then state.
- Own what we are: no account, pair once, approve on your Mac.
- Candidate headlines (mine): Your Mac, wherever you are. / Leave the desk. Keep the Mac. / Your desk fits in your pocket. / Reach across the country like you reach across the room. / Pick up your Mac like you pick up your phone.

#### 4.3.2 Section list

| # | Section | Purpose | Technique | Reference |
|---|---|---|---|---|
| 0 | Slim announcement bar | Beta and version status | Static | Wispr |
| 1 | Floating pill nav | Features, How it works, Security, Pricing, Download; platform-aware button; a Mac / iPhone toggle | Sticky | Wispr |
| 2 | Hero | The brand device performing the product (see 4.3.3), one button, a microline: macOS and iOS versions, no account | Custom | Wispr, Flighty |
| 3 | Proof strip | Until press exists: what people run on their Mac while away (editors, agents, design tools), or a short honest "made in the open" note | Static | Workbench press row, timespent note |
| 4 | See it in 20 seconds | A real recorded session with polished zoom, on a phone frame beside the Mac | Video from our own tool | Screen Studio |
| 5 | How it works | Pinned three-step story: install on Mac, scan, control | One ScrollTrigger pin | Wispr, Dia |
| 6 | The feel | Gesture explainer with animated finger trails, and a "try it" trackpad the visitor can play with in the browser | Small canvas demo | Raycast keyboard |
| 7 | Agents | Approve prompts and check on long tasks from your phone; the benchmark's core audience | Chip cards | Workbench, Flighty |
| 8 | Anywhere | Direct on home Wi-Fi, secure relay elsewhere; only measured numbers | Route line | Flighty |
| 9 | Privacy and security | No account, pairing by QR with approval on the Mac, encryption details, what is and is not stored | Diagram, real badges only | Wispr, Tailscale |
| 10 | Details for pros | Keyboard bar, dynamic zoom, pointer, multi-display, haptics: a bento grid of tiny looping clips | Video loops | Raycast, Linear |
| 11 | Voices | Real quotes only; until then a short founder note, hand-signed | Tilted cards later | Wispr, timespent |
| 12 | Pricing | Honest free tier; monthly, annual, and optionally one-time; a small comparison; no dark patterns | Toggle | Wispr, Workbench |
| 13 | FAQ | Chat-shaped: "Do I need an account?", "Can anyone see my screen?", "What if Wi-Fi drops?", "Does my Mac need to be awake?", "Why does macOS keep asking for permission?", "Does it work on iPad?", "What does it cost?" | Chat list | Wispr, Navigate |
| 14 | Closer | Cinematic image, one button, a QR to the phone app | Photo | Perplexity, Wispr |
| 15 | Footer | Giant wordmark, changelog, status line, media kit, compare pages | Static | Wispr, Aqua |

Extra pages worth having: a download page that detects platform, a security page, a changelog, an honest compare page (Workbench, Jump, Screens), a help page that mirrors the in-app troubleshooter, and a media kit.

#### 4.3.3 Hero concepts showing a phone controlling a Mac

1. **Tether.** A single luminous line runs from a thumb on the phone across the page to a Mac's pointer. Scroll pulls it; the pointer clicks something. Text can ride the line, echoing Wispr's ribbon [I].
2. **Live chips.** A phone in a hand, surrounded by chips that update as you scroll: a build finished, an agent asks for approval, a meeting starts. Borrowed from Flighty's notification chips [I].
3. **Try it now.** The hero is interactive: the visitor drags on a mock phone trackpad and a mock Mac's pointer follows; a click opens a window. It shows "just works" in five seconds with no install [I].
4. **Pocket and desk.** A split screen: a desk on the left, a pocket on the right; scrolling collapses the desk into the phone. Workbench uses a static version of this idea with a Mac mini and phone [L].
5. **Cinematic still life.** A 3D render of a Mac and phone in a quiet setting with a glass bubble, as Perplexity does [L].
6. **Menu bar reveal.** A close crop of a macOS menu bar; our icon wakes; the frame zooms out to the whole desktop and then to a phone in hand [I].
7. **Type as image.** A giant serif word the cursor can wipe to reveal a second word [I].
8. **Time of day.** The same Mac on a desk from morning to night while the phone stays with a person in motion; scroll advances the sun [I].

#### 4.3.4 Animation ideas and budget

| Idea | Source |
|---|---|
| Pinned three-step story, one visual, three states | Wispr, Dia |
| Text or dots riding a path, drawn on scroll | Wispr hero |
| Hand-drawn underline that draws on hover or in view | Wispr |
| Tilted card scatter for quotes | Wispr |
| Chat-shaped FAQ | Wispr, Navigate |
| Sticky bottom pill that changes from Download to a chapter indicator | Dia, Flighty |
| Chips orbiting a phone | Flighty |
| Giant wordmark footer | Wispr |
| Icon as hero | Things, Screen Studio |
| Optional "hear it": the site plays the app's real sounds on interaction, muted by default | Idea [I] |

Budget: keep to a handful of scroll triggers, as Wispr does (six in total, one pinned). Everything else CSS or video. Respect `prefers-reduced-motion` with poster frames. No autoplay audio. Lazy-load video below the fold. Compress demos as WebM and MP4 with alpha where needed. Skip third-party trackers and consent banners, and say so on the privacy page: for this product "no cookie banner" is a feature.

#### 4.3.5 Build approach

The owner already has a Paperwash kit (`~/.agents/skills/paperwash`) with warm paper tokens, seven tone colours, Source Serif 4, DM Sans, JetBrains Mono, GSAP and a single-file bundler. Direction 1 could be built almost entirely from it. For any direction: Astro or Next.js with bun and TypeScript per the owner's preferences, GSAP ScrollTrigger for the one pinned story, and small Rive or Lottie pieces for spot animation. Record demos with a screen-recording tool that adds smooth zooms, then composite the phone frame. The Wispr site itself proves a Webflow build with a modest script budget can look this good, so the constraint is design attention, not stack.

---

## 5. Limits and open questions

- I did not see Wispr Flow's Hub or Flow bar on screen. The description of the Mac app is from Wispr's help centre, Mobbin's iOS captures and the bundle contents. A five-minute look at the running app would close this.
- Mobbin has no macOS catalogue. Mac patterns rest on web sections and iOS analogues.
- Apple's HIG pages did not render in the fetch tool. HIG rules quoted from the audit were not re-verified here.
- The iOS 27 Liquid Glass retune (transparency slider, darker edges, layered icons) comes from secondary sources. Read Apple's own release notes before designing against a specific behaviour.
- Fetch-tool summaries of other sites' colours and animation are approximate. Only the Wispr site was measured. Read computed styles before copying a value from any other site.
- The Workbench pricing figures differ between the April press and the site fetched today. Verify before quoting.
- Haptics on iPad: believed absent, not verified.
- Third-party claims about Wispr's privacy behaviour come from review roundups, not from Wispr.
- Do the ideas fit the current build? Anything touching the streamed picture (tether overlay, edge glow, shaders) must be tested for cost and for not obscuring content.
- Decisions the owner needs to make: how far from Apple-native to go (PRODUCT currently says Apple-native with faint Paperwash), whether to lead with agents or general use, whether sound is on by default, and whether the brand gets a character.

---

## 6. Reference index

### Wispr Flow
- Site: [wisprflow.ai](https://wisprflow.ai), [pricing](https://wisprflow.ai/pricing), [what's new](https://wisprflow.ai/whats-new), [rebrand case study](https://wisprflow.ai/rebrand)
- Help centre: [setup guide](https://docs.wisprflow.ai/articles/3152211871-setup-guide), [navigating the app](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android), [starting your first dictation](https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation), [product-aware onboarding on macOS](https://docs.wisprflow.ai/articles/5926242953-product-aware-onboarding-choosing-dictation-notetaker-or-both-macos)
- Design token extractions: [Refero](https://styles.refero.design/style/ac53825c-1e06-4ae0-8489-cace5c5e0339), [Fudge](https://design.withfudge.com/share/wisprflow.ai-design), [SaaS Landing Page](https://saaslandingpage.com/wispr-flow/), [Aceternity text animation lab](https://ui.aceternity.com/labs/wispr-flow-text-animation)
- Analysis: [Kristen Berman, eight lessons from the onboarding](https://kristenberman.substack.com/p/wispr-flow-8-lessons-from-the-best), [Cult of Mac review](https://www.cultofmac.com/reviews/wispr-flow-mac-speech-to-text-app-review), [LinkedIn post on speech-based onboarding](https://www.linkedin.com/posts/parameswaranv_speechai-speechhci-hci-activity-7430865500307599360-1nIK)
- Local: `/Applications/Wispr Flow.app` v1.6.447, `Contents/Resources/assets/` (sounds, lottie, illustrations, videos)
- Mobbin: see 3.3 (onboarding flow, account setup flow, [home flow](https://mobbin.com/flows/aeb81b1d-124c-49d5-9e41-ce40acc34a33))

### Sites and apps
- [Raycast](https://www.raycast.com), [Page Flows: Raycast onboarding](https://pageflows.com/post/desktop-web/onboarding/raycast/)
- [Linear](https://linear.app)
- [Dia](https://www.diabrowser.com), [Arc onboarding on SaaSUI](https://www.saasui.design/pattern/onboarding/arc-browser), [George's SwiftUI Arc/Dia-style onboarding breakdown (X)](https://x.com/georgecartridge/status/1938365312157544860) (not fetched, cited from search)
- [Things](https://culturedcode.com/things/)
- [CleanShot X](https://cleanshot.com)
- [Screen Studio](https://screen.studio)
- [Granola](https://www.granola.ai)
- [Flighty](https://flighty.com)
- [Superhuman](https://superhuman.com), [First Round: Superhuman's onboarding playbook](https://review.firstround.com/superhuman-onboarding-playbook/), [Flowjam teardown](https://www.flowjam.com/blog/superhuman-onboarding-teardown-30-minute-wow-session)
- [Perplexity Personal Computer](https://www.perplexity.ai/personal-computer), [MacRumors launch](https://www.macrumors.com/2026/04/16/perplexity-personal-computer-for-mac/), [TechCrunch general availability](https://techcrunch.com/2026/05/07/perplexitys-personal-computer-is-now-available-everyone-on-mac/)
- [Astropad Workbench](https://astropad.com/product/workbench/), [Workbench iPhone setup help](https://support.astropad.com/en/articles/14025859-setting-up-workbench-on-your-ipad-iphone), [App Store listing](https://apps.apple.com/us/app/astropad-workbench/id6758788573), [MacRumors](https://www.macrumors.com/2026/04/08/astropad-workbench-app/)
- [Jump Desktop](https://jumpdesktop.com), [Screens 5](https://edovia.com/en/screens)
- [Tailscale](https://tailscale.com)
- [Apple Continuity](https://www.apple.com/macos/continuity/)
- Galleries for more: [One Page Love macOS tag](https://onepagelove.com/tag/macos), [Lapa Ninja app pages](https://www.lapa.ninja/category/app/)

### Apple and platform
- [Apple Design Awards 2026 winners](https://www.apple.com/newsroom/2026/06/apple-reveals-winners-of-the-2026-apple-design-awards/)
- SwiftUI docs (via context7): [glassEffect(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffect%28_%3Ain%3A%29), [glassEffectID(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffectid%28_%3Ain%3A%29), [Glass.interactive](https://developer.apple.com/documentation/swiftui/glass/interactive%28_%3A%29), [SensoryFeedback](https://developer.apple.com/documentation/swiftui/sensoryfeedback), [sensoryFeedback(trigger:_:)](https://developer.apple.com/documentation/swiftui/view/sensoryfeedback%28trigger%3A_%3A%29), [MeshGradient](https://developer.apple.com/documentation/swiftui/meshgradient/init%28width%3Aheight%3Abezierpoints%3Acolors%3Abackground%3Asmoothscolors%3Acolorspace%3A%29), [PhaseAnimator](https://developer.apple.com/documentation/swiftui/phaseanimator/init%28_%3Atrigger%3Acontent%3Aanimation%3A%29), [colorEffect](https://developer.apple.com/documentation/swiftui/view/coloreffect%28_%3Aisenabled%3A%29), [distortionEffect](https://developer.apple.com/documentation/swiftui/view/distortioneffect%28_%3Amaxsampleoffset%3Aisenabled%3A%29), [fontDesign](https://developer.apple.com/documentation/swiftui/view/fontdesign%28_%3A%29), [Font.Width](https://developer.apple.com/documentation/swiftui/font/width), [MenuBarExtra](https://developer.apple.com/documentation/SwiftUI/MenuBarExtra), [MenuBarExtraStyle.window](https://developer.apple.com/documentation/swiftui/menubarextrastyle/window)
- Secondary: [WWDC26 What's new in SwiftUI breakdown](https://dev.to/arshtechpro/wwdc26-whats-new-in-swiftui-a-developers-breakdown-1333), [Liquid Glass in Xcode 27 migration](https://ecorpit.com/ios-27-liquid-glass-xcode-27-migration-guide-2026/)

### Internal
- `UX-AUDIT.md` (this folder), `PRODUCT.md`, `Docs/COMPETITOR-LANDSCAPE-2026-09-28.md`, `Docs/PHONE-REDESIGN-RECEIPT-2026-09-28.md`, `Docs/HOST-REDESIGN-RECEIPT-2026-09-28.md`
- Paperwash kit: `~/.agents/skills/paperwash` (tokens: paper `#FAF9F5`, ink `#141413`, seven tones)

---

## 7. Ten design directions we could prototype

Each direction is a distinct brand concept, not a re-skin. All palettes and values are starting points to test on device and in a browser. All keep Liquid Glass confined to the control layer, keep the streamed picture sharp, and keep the Mac companion a menu bar app. Each lists the signature device, the mood, palette, type, motion, sound and haptic character, a hero idea for the site, how the phone session feels, and the main risk. Name territories are ideas only.

### Direction 1: Paperwash Pocket

- **Mood:** A well-made notebook that happens to control your Mac. Warm, literate, calm. Closest to Wispr Flow and to the owner's own Paperwash house style.
- **Palette:** Paper `#FAF9F5`, ink `#141413`, card `#F5F4ED`, lines `#E6E3D9`. One action colour: deep lilac `#5E4CC4` (Paperwash d0). Tone tiles carry state: sage `#9DC5A6` connected, straw `#E0D2AD` waiting, clay `#E7AA8E` needs attention, sky `#93B6EC` information. Dark mode warm charcoal `#1B1A17`.
- **Type:** Source Serif 4 on the web, the system serif (New York) on device for titles; DM Sans or SF Pro for UI; a mono for latency.
- **Motion:** Slow and gentle: fade with an 8 point rise (`settle`), tone tiles that bleed into place, underlines that draw. Nothing bounces.
- **Sound and haptics:** A soft wooden tock and a paper flick, each under 250 ms; light selection haptics.
- **Site hero:** A large serif headline with an italic last word. Beneath it, a phone resting on a paper desk; a hand-drawn dotted pencil line draws from the phone to a sketched Mac as you scroll, and a pointer travels along it. Sections are tone-tile chapters. Built almost entirely from the Paperwash kit.
- **Phone session:** Full-bleed Mac. The dock is a frosted paper-toned glass pill with serif labels; the status dot uses tile colours. Home shows the Mac as a paper card with a tone-tile header and a live thumbnail.
- **Mac companion:** A monoline menu bar glyph; a setup window that looks like a paper card with ink-outlined sticker illustrations.
- **Name territory:** Notebook, Margin, Folio.
- **Risk:** The most likely to read as derivative of Wispr; needs its own illustration style and device. Warm neutrals need contrast care.

### Direction 2: Nocturne Glass

- **Mood:** A late-night control room. Cinematic, glassy, luminous. Perplexity's site, Raycast, Screen Studio.
- **Palette:** Near-black `#0B0D10`, glass whites at 8 to 16 percent, text `#EDEFF2` and `#9AA3AD`. Glow accent aurora teal `#5CE1C6`, secondary violet `#8B7CFF` for gradients.
- **Type:** SF Pro Display with tight tracking; system serif for statement lines such as "Always on".
- **Motion:** Slow parallax, a light bloom when the phone connects, glass that morphs between dock and keyboard (`glassEffectID`), a breathing `MeshGradient` behind Home.
- **Sound and haptics:** Deep, reverberant soft pings; soft and rigid impacts.
- **Site hero:** A cinematic 3D render (a Mac and phone with a glass bubble in a dark landscape) lit by a light that follows the cursor; a serif headline; product UI as a translucent glass panel.
- **Phone session:** Home is a dark canvas with your Mac as a glowing card; session chrome is glass tinted by connection health.
- **Mac companion:** A dark glass setup window; a menu bar chip like Perplexity's mockup.
- **Name territory:** Vantage, Nocturne, Halo.
- **Risk:** Reads as "AI product" cliché. Glass legibility varies with the reported iOS 27 transparency slider. Dark-on-dark contrast.

### Direction 3: Signal

- **Mood:** Pilot-grade instrumentation. Flighty's "get the truth" applied to your Mac: trust through readable data.
- **Palette:** Deep navy `#0A1220`, panels `#121C2E`, instrument amber `#FFB020` as the accent, go-green `#34D399`, alert red `#FF5D5D`, text `#E8EEF7`. Light mode white with navy ink.
- **Type:** SF Pro Expanded for numbers, SF Mono for readouts, rolling numerals with `contentTransition(.numericText)`.
- **Motion:** Gauges that sweep, radar sweeps while connecting, rolling numbers, status changes that flip like a departures board.
- **Sound and haptics:** Crisp two-tone cockpit chimes; haptic detents for zoom levels and edges.
- **Site hero:** A phone in a hand with chips around it (latency, encrypted, "an agent is asking to run a command"), Flighty-style, over a quiet dark ground. A chapter pill at the bottom steps through: at home, on the move, in the office.
- **Phone session:** A tiny HUD dot shows link quality; tapping it expands a flight-strip-style panel with a plain diagnosis (the audit's troubleshooter). Errors read as cause then action.
- **Mac companion:** Menu bar glyph with a micro latency graph; a menu that lists the connected phone with link quality.
- **Name territory:** Signal, Beacon, Heading.
- **Risk:** Cold and geeky if overdone. Only display numbers we have measured. Instruments can crowd a small screen.

### Direction 4: Tether

- **Mood:** One idea, executed well: a single line connects your touch to your Mac. Minimal, kinetic, confident.
- **Palette:** Bone `#F2F0EA` and graphite `#111214`; one accent, vermilion `#FF4B2B`, used for the line and nothing else.
- **Type:** SF Pro Rounded semibold plus `fontWidth(.expanded)` bold for headlines.
- **Motion:** The tether is the brand device. In onboarding it draws from the QR code to the menu bar icon. In session an optional thin ribbon trails the finger's contact point to the pointer, easing with a spring lag, then fading. Reconnecting looks like the line re-tying.
- **Sound and haptics:** A plucked-string tone; taut and slack haptics using impact flexibility (soft to rigid).
- **Site hero:** A vermilion thread runs down the whole page linking every section; in the hero a phone at left and a Mac at right are joined by it, and scrolling pulls it taut until the pointer clicks.
- **Phone session:** The optional trail is genuinely useful as a teaching aid: it makes the relative-trackpad model visible (the pointer does not jump to your finger), which the audit names as the biggest missing teaching moment. It fades after the first few sessions.
- **Mac companion:** A menu bar glyph that is a small looped line; a setup window where the line connects each completed row.
- **Name territory:** Tether, Lead, Thread.
- **Risk:** A gimmick if overdone; a persistent trail over the picture may distract, so it must be a fading aid and a toggle. Needs performance testing.

### Direction 5: Golden Hour

- **Mood:** Sunlit and human. Dappled light on a desk, the ease of leaving it. Dia's warmth, with photography.
- **Palette:** Butter `#F6D25F`, apricot `#F2A65A`, cream `#FFF7E3`, cocoa ink `#2A1E14`, a small sky-blue `#5B8DEF` accent for actions.
- **Type:** System serif large plus SF Pro. A soft italic for warmth.
- **Motion:** Slow light: a subtle dapple over chrome, drifting; the interface warms slightly in the evening based on the time of day. Springs are gentle.
- **Sound and haptics:** Warm mallet or marimba tones; soft impacts.
- **Site hero:** A photograph or render of an empty desk with a sun patch and a phone in a hand walking away; scrolling moves the sun across the desk. The headline is about the desk fitting in your pocket.
- **Phone session:** Home greets by time of day ("your MacBook is home, resting"); session chrome is warm glass; edge glow is amber when degraded.
- **Mac companion:** A sun glyph with three states; a friendly, bright setup window.
- **Name territory:** Lamp, Noon, Porch.
- **Risk:** Photography or 3D production cost. Reads less technical to power users. Warm on warm can hurt legibility.

### Direction 6: Tactile

- **Mood:** A physical object: machined trackpad, a knurled dial, keycaps. Teenage Engineering and Braun energy.
- **Palette:** Aluminium `#D9DBDD`, graphite `#2B2D2F`, off-white `#F4F4F2`, signal orange `#FF5B1F`, LED green `#6BFF9E` for connected.
- **Type:** A monospaced label face (SF Mono or a licensed alternative) plus SF Pro; big numerals.
- **Motion:** Short, precise, mechanical; buttons that press in; an LED glow; a dial that rotates for sensitivity with detents.
- **Sound and haptics:** Real recorded mechanical clicks, a different one for each action, on by default with a toggle. Rich Core Haptics detents for zoom levels and textured scroll ticks. On iPad sound carries it.
- **Site hero:** A 3D trackpad object floating and rotating until it becomes the phone screen; visitors can click it and hear it.
- **Phone session:** The touch surface has a subtle machined texture; dock buttons look like keycaps; sensitivity is a physical-looking dial.
- **Mac companion:** A menu bar glyph like a small trackpad; the menu lists devices like a hardware panel.
- **Name territory:** Pad, Dial, Detent.
- **Risk:** Skeuomorphism sits against Liquid Glass and Apple-native fit. Asset-heavy (3D, recorded sound). iPad lacks haptics.

### Direction 7: Pointy

- **Mood:** Friendly and funny. The pointer is a character who lives in your Mac and waves from the menu bar. Duolingo warmth, Wispr's sticker illustrations, Things' pride in its icon.
- **Palette:** Sun `#FFD23F`, cobalt `#2E5BFF`, bubblegum `#FF8FB1`, mint `#7EE2B8`, ink `#1A1A1A`, off-white `#FFFDF5`, with 2 px ink outlines.
- **Type:** SF Pro Rounded heavy for headlines (`fontDesign(.rounded)`), SF Pro for body.
- **Motion:** Squash-and-stretch springs. The character reacts: asleep when the Mac sleeps, running while connecting, a thumbs-up on connected. Driven by a state machine in Rive.
- **Sound and haptics:** Playful, wordless boops; springy impacts.
- **Site hero:** The character hauls a Mac toward a phone on a rope, bouncing; scrolling triggers sticker-slap moments; the cursor becomes a sticker.
- **Phone session:** Mostly chrome-free; the character appears in coach beats (a pointing hand shows each gesture), empty states and errors.
- **Mac companion:** A menu bar character with moods; setup window steps narrated by the character.
- **Name territory:** Pip, Nib, Cursorling.
- **Risk:** May cheapen "Apple quality" for professional users of agents. Character design and animation cost. Highest differentiation in the category by a wide margin.

### Direction 8: Swiss Kinetic

- **Mood:** Confident typography on a strict grid. Plain, but perfect. Linear and Vercel restraint with more warmth.
- **Palette:** White `#FFFFFF`, black `#0A0A0A`, greys, one Swiss red `#E5251B`.
- **Type:** SF Pro Display Expanded heavy at very large sizes; SF Mono for data. 120 to 200 pt on the web.
- **Motion:** Kinetic type: words slot in, numerals roll, hard cuts with precise easing (fast in, long settle). No glass beyond the system's.
- **Sound and haptics:** Near silent: a single tick; crisp haptics.
- **Site hero:** A viewport-filling word, "Reach.", that the cursor can wipe to reveal "Your Mac." The rest of the site is a monumental grid with numbered sections and only real UI as imagery.
- **Phone session:** Chrome reduced to hairlines and type; a text-only dock; a single red dot for status. The fastest-feeling of the ten.
- **Mac companion:** A text-only menu; a setup window that is a numbered list.
- **Name territory:** Reach, Grid, Far.
- **Risk:** Could still read as plain to the owner; depends entirely on type craft; least delightful.

### Direction 9: Aurora

- **Mood:** It feels like an Apple system feature: a living gradient that reflects connection state, like Siri's edge light or iPhone Mirroring. The safest, most native option.
- **Palette:** System backgrounds plus state gradients: idle indigo to blue, connecting cyan to violet pulse, connected mint to teal, degraded amber. Built with `MeshGradient` (iOS 18 and macOS 15 or later).
- **Type:** SF Pro and SF Pro Rounded; system serif for the hero line.
- **Motion:** Gradient breathing over 6 to 8 seconds; an edge-light sweep when the connection succeeds; glass that morphs between dock and keyboard bar; symbol effects on icons.
- **Sound and haptics:** Glassy, gentle system-like tones; standard sensory feedback.
- **Site hero:** A large soft gradient canvas that reacts to the cursor, with glass renders of a phone and a Mac; type set to feel like an Apple page.
- **Phone session:** A subtle glowing border while connected, colour-coded by state, which doubles as a "you are controlling a computer" security indicator. Home's hero card is a living gradient.
- **Mac companion:** A brief screen-edge glow when a phone connects, then the menu bar icon; a setup window with a gradient header that turns green as rows complete.
- **Name territory:** Aurora, Glow, Horizon.
- **Risk:** May feel generic-Apple and easy to confuse with system UI. `MeshGradient` cost and battery need measurement. Needs Reduce Motion and Reduce Transparency handling. iOS 27 glass retune may shift the look.

### Direction 10: Agent Console

- **Mood:** Terminal-native and keyboard-first, for people who run agents and long tasks on a Mac they are away from. Workbench's core audience, with a distinct voice.
- **Palette:** Charcoal `#0F1115`, panel `#171A21`, phosphor green `#7CFFB2` and amber `#FFC857`, text `#D7DEE9`, dim `#7B8494`.
- **Type:** JetBrains Mono or SF Mono for headings and chips, SF Pro for body.
- **Motion:** A caret blink, command-palette transitions with matched geometry, status chips that animate like CI runs. Scanline texture only on the marketing site.
- **Sound and haptics:** Terse blips; approve is a double tick.
- **Site hero:** A split screen of phone and Mac: an agent on the Mac asks permission to run a command; a thumb taps Approve on the phone; the terminal carries on. The angle is approving from anywhere, distinct from Workbench's wording about agents that do not stop.
- **Phone session:** A quick-action rail (Approve, Deny, Esc, Enter, copy), agent-status chips (running, waiting, done), a keyboard accessory bar for shortcuts; the picture is the fallback view.
- **Mac companion:** A menu that lists running long tasks and their state; a setup window that reads like a checklist in a terminal.
- **Name territory:** Console, Relay, Approve.
- **Risk:** Narrow audience against the "just works for everyone" brief. Fits the PRODUCT goal of exceeding Workbench on agent integration, but agent hooks are not yet built.

### Comparison

Scores are my judgement (1 low, 5 high), not measured.

| # | Direction | Apple-native fit | Owner taste (Wispr, Paperwash) | Differentiation in category | Site effort (low is easy) | App effort (low is easy) |
|---|---|---|---|---|---|---|
| 1 | Paperwash Pocket | 4 | 5 | 3 | 1 | 2 |
| 2 | Nocturne Glass | 4 | 3 | 2 | 3 | 3 |
| 3 | Signal | 4 | 2 | 4 | 3 | 3 |
| 4 | Tether | 4 | 3 | 5 | 3 | 3 |
| 5 | Golden Hour | 3 | 4 | 4 | 5 | 3 |
| 6 | Tactile | 2 | 2 | 5 | 5 | 5 |
| 7 | Pointy | 3 | 3 | 5 | 4 | 4 |
| 8 | Swiss Kinetic | 4 | 2 | 2 | 2 | 1 |
| 9 | Aurora | 5 | 3 | 2 | 3 | 3 |
| 10 | Agent Console | 3 | 2 | 3 | 3 | 3 |

### How to prototype and what to pick first

Run every direction through the same four artifacts, each in about two days, so they can be compared side by side on a phone and in a browser:

1. The Home card for a paired Mac (online, last seen, Connect).
2. The session dock, closed and open, over a real streamed frame.
3. One Mac setup step (the permission checklist with one row completing).
4. The site hero at desktop and phone width.

Score them with five-second tests on three people who have not seen the product, and by watching what they say the product is for. Add a fifth artifact only for the finalists: the 20-second gesture coach.

**Recommendation.** Prototype Directions 1, 9 and 4 first. Direction 1 fits the owner's taste and reuses the Paperwash kit so the site is cheap to build. Direction 9 is the Apple-native safe baseline and its state-coloured glow doubles as a security indicator. Direction 4 supplies the one thing the category lacks, a brand device that teaches the trackpad model. A likely winner is a hybrid: the Paperwash Pocket surface and voice, Tether as the brand device, and Aurora's state glow reduced to a single quiet edge light. Keep Direction 7 (Pointy) as the wild card if the owner wants the biggest possible gap from Workbench, and Direction 10 (Agent Console) as the persona layer for an agents landing page rather than a whole-brand direction.
