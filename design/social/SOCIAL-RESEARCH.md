# Farside on social: what works in 2026 (research before the kit)

Researched Monday 28 September 2026, the night before the owner opens the accounts. Research only: nothing was posted, no account was created, no one was contacted. The launch kit in `design/social/` and `~/Downloads/farside-social/` was designed **after** this file and follows section 9.

Evidence labels:

- **[P]** primary: the platform's own docs, system cards, open-sourced code, or an executive's own post.
- **[T]** trade press reporting a platform statement (Social Media Today, TechCrunch).
- **[V]** vendor or practitioner study (Buffer, Sprout Social, Hootsuite, Socialinsider). Large samples, but their customers skew to brands; treat numbers as direction, not law.
- **[C]** case study told by the founder or a named analyst.
- **[I]** my inference for Farside. Challenge it.

---

## 0. Do this (the ten rules the kit follows)

1. **Win the first second, not the first three.** Instagram's Reels ranker predicts "how likely you are to watch less than three seconds" and "how likely you are to watch more of a reel than 95% of users who watched reels of the same length" [P]. Every video opens mid-motion with the hook already on screen at frame 0; no fade-ins, no logo intros.
2. **Design to be sent.** Instagram: sends per reach matters most for reaching non-followers, likes per reach for followers, watch time overall [T, Mosseri Jan 2025]. X predicts "share via DM" and "share via copy link" [P]. The jokes are written so one person sends them to the friend whose Mac is across the room.
3. **Short loops for a cold account.** 7 to 15 s clips that loop cleanly (replays count as watch time) [T/V]. Longer demos (30 to 60 s, real footage) come later; a 2026 study of business Reels found 45 to 60 s had the best median views, but that is for accounts with an audience [V].
4. **Original, native, watermark-free, per platform.** Instagram removed aggregators from recommendations for photos and carousels on 30 Apr 2026, and says a watermark or a credit does not make a repost original [P/T]. TikTok lists "someone else's visible watermark or superimposed logo" as unoriginal [P]. Upload our clean masters to each app; never re-upload a TikTok download to Reels.
5. **Text on screen, few words, inside the safe zone.** Sound is often off; TikTok's own guidance: "Use captions or text overlays to provide context" and introduce the proposition "in the first 3 seconds" [P]. The kit's safe text box on 1080x1920 is **x 65 to 960, y 270 to 1440** (stricter than the brief's top 220 / bottom 420 / right 120, so it also clears Meta's 14% top and the Reels grid crop).
6. **Hashtags describe, they don't boost.** Instagram caps posts at **5 hashtags** (since Dec 2025) and Mosseri says hashtags don't increase reach [T]. X: 0 to 1. Threads: **one topic tag** per post [P]. TikTok: 3 to 5, keyword-style, because captions and hashtags are part of "video information" [P].
7. **No link in the main X post.** X says link posts get lower reach because the browser covers the post and engagement drops; it has been testing an in-app browser since Oct 2025 [P]. Put the link in the first reply and the bio. Threads links are fine since mid-2025 [T].
8. **Reply to everyone, fast.** Buffer's 2026 data: posts where the brand replies to comments earn more engagement, strongest on Threads (+42%) [V]. X predicts replies and ranks the author's own replies in the conversation [P].
9. **Cadence a solo owner can keep for 14 days:** X 2 to 3 posts a day plus replies; Threads 1 to 2 a day; Instagram 4 to 5 a week (3 Reels, 1 to 2 carousels or stills); TikTok 4 to 5 a week. That sits inside Buffer's and Hootsuite's 2026 ranges [V].
10. **Everything in this kit is code-rendered, not AI-generated.** No AI label is needed. If Higgsfield or any generator is used later, label it on every platform (TikTok requires labels on realistic AI content; Meta shows "AI info"; X has a "Made with AI" toggle) [P/T].

---

## 1. Cross-platform facts

### 1.1 Recommendation-first feeds; follower count is not the gate

- **TikTok:** "neither follower count nor whether the account has had previous high-performing videos are direct factors in the recommendation system"; a strong signal such as finishing a longer video weighs more than a weak one [P, TikTok Newsroom, 18 Jun 2020, still linked from TikTok's transparency pages].
- **X:** the open-sourced For You stack (xai-org/x-algorithm, Aug 2026 revision) has a **new-author boost**: "posts from authors whose impressions are below a threshold are lifted toward a target position". Out-of-network posts are multiplied by a factor below 1; repeated posts from one author decay ("each post after an author's first is multiplied by a decaying factor"); posts older than 48 hours are filtered [P].
- **Instagram:** reach to non-followers comes from Explore and the Reels tab; the Reels ranker's predictions are listed in 2.2 [P].
- **Threads:** Mosseri rebalanced ranking in Nov 2024 to "prioritize content from people you follow", so "unconnected reach go down and connected reach go up" [P]. Strangers are harder to reach on Threads than on the other three; replies are how you get found.

**[I] For a brand-new account:** TikTok and X give a new account a real shot at strangers on day one; Instagram rewards shares and watch time; Threads rewards conversation. So video-first on TikTok and Reels, conversation-first on Threads, a mix on X.

### 1.2 Originality and watermarks

| Platform | Rule | Evidence |
|---|---|---|
| Instagram | Accounts that mostly repost lose recommendation eligibility for photos, carousels and reels (extended from Reels to photos and carousels on 30 Apr 2026). "Re-uploading someone else's work ... without adding meaningful creative input ... such as just adding a border, watermark, subtitles, or a credit in the captions" is not original. Eligibility returns when most posts in a rolling 30 days are original. | [P] Instagram for Creators; [T] TechCrunch 30 Apr 2026 |
| TikTok | Unoriginal content includes content "largely repurposed from another source without adding any creative edits" and "content with someone else's visible watermark or superimposed logo"; such videos can be made ineligible for the For You feed (still visible on the profile and in search). | [P] TikTok FYF eligibility standards / Creator Academy (via page text in search results; the pages render client-side) |

**[I]** Our masters carry no platform watermark. Post each natively; for X and Threads, upload the file rather than linking a TikTok.

### 1.3 AI-content labels

- **TikTok:** "We require people to label realistic AI-generated content"; auto-labels via C2PA Content Credentials (1.3 billion videos labelled by Nov 2025); invisible watermarks on TikTok-made AI content; users can now dial AI content down in Manage topics [P, TikTok Newsroom, 19 Nov 2025].
- **Meta (Instagram, Threads):** an "AI info" label is applied when Meta detects "industry standard AI image indicators" or when people disclose AI content [P, Meta Transparency Center]. Practitioner summaries say photorealistic AI video and realistic audio must be disclosed [V].
- **X:** a post-level "Made with AI" disclosure toggle, tested Feb 2026 and rolled out in March 2026 [T].

**[I]** The kit is HTML/canvas/SVG rendered in headless Chrome and encoded with ffmpeg: no generative model touched it, so no label applies. Do not strip or add metadata. If the owner later uses Higgsfield plates (VIDEO-PLAYBOOK.md), switch the label on.

### 1.4 Music and sounds for a brand account

- **TikTok Business accounts** can use only the **Commercial Music Library** (pre-cleared for brands); trending chart sounds do not appear for them, and CML rights cover TikTok only [V, Soundstripe and others].
- **Instagram Business accounts** get the smaller **Meta Sound Collection**; the full library is licensed for personal, non-commercial use [V].
- The Reels ranker predicts "how likely you are to use the audio from a reel you're viewing in one you create" [P]. An **original, named sound** can earn that signal for us.

**[I]** Use an original sound (the owner's real tap-and-click foley, or a minimal pad) named "farside · the click", or a CML / Meta Sound Collection track matched to the vibe notes in `copy/videos.md`. Each video's note describes the vibe; it does not name copyrighted songs.

### 1.5 Hooks and on-screen text

- TikTok: "Introduce your content proposition in the first 3 seconds"; "Prioritize your hook in the first 6 seconds"; use captions or text overlays; a DIY, not over-polished look; feature real people; a clear CTA [P, TikTok Ads creative best practices, updated Jun 2025].
- Instagram designs Reels to be followed without sound; the bottom of a Reel is covered by the caption and audio line [V].
- **[I] Hook patterns that fit Farside's deadpan voice:** a status line that creates a question ("Someone is controlling your Mac"), POV ("POV: your Mac is at home and you're on the train"), a counter already moving (8,421 km ticking down), a mild provocation ("Please don't walk back to your desk"), and "wait for the click". Payoff lands between 2 and 4 s; the last frame hands back to the first so the loop is seamless.

### 1.6 Safe zones (1080x1920)

| Source | Top | Bottom | Sides |
|---|---|---|---|
| The brief (TikTok and Reels) | 220 px | 420 px | right 120 px |
| TikTok In-Feed (practitioner reading of TikTok specs) | 150 px | 440 px | 60 px |
| Meta Reels and Stories (Meta Ads Guide, Aug 2026; a recommendation) | 14% (269 px) | 35% (672 px) | 6% (65 px) |
| Instagram grid preview of a Reel cover | shows the centre 3:4 (y 240 to 1680) | | |

**Kit rule:** key text in **x 65 to 960, y 270 to 1440**. Art may run full-bleed. The Meta 35% bottom is an ad figure (it leaves room for a CTA button); organic captions cover less, so the kit uses 480 px and keeps end-card text above y 1400.

### 1.7 Specs that matter for this kit

| Platform | Stills | Video |
|---|---|---|
| Instagram | 1080x1350 (4:5) is the feed default; the profile grid shows posts as **3:4 tiles** since Jan 2025, trimming about 34 px from each side of a 4:5 post and a lot more from a 1:1 post (only the centre 810 px of a square shows) [T/V] | 1080x1920 Reels |
| X | 1600x900 (16:9) and 1080x1350 (4:5) show uncropped in single-image posts [V] | up to 1920x1200 / 1200x1920, 140 s on free accounts, 40 fps cap on web upload [V]; our 16:9 cuts are 1920x1080 |
| Threads | images and video, up to 20 per post; 500-character text [V] | 9:16 or 4:5 |
| TikTok | photo mode exists; Buffer finds images engage below video on TikTok (1.92% vs 3.39%) [V] | 1080x1920, at least 720p [P] |

Alt text: X allows 1,000 characters. Instagram's in-app limit is reported inconsistently (100 to 1,000); the kit keeps alt text under 100 characters for Instagram and adds longer versions for X [V].

---

## 2. Instagram

### 2.1 How ranking works now

- **Three signals Mosseri named (Jan 2025):** watch time; likes per reach (weighted more with followers); sends per reach (weighted more with non-followers) [T, Social Media Today]. Practitioner claims that a send is worth "3 to 5 likes" are estimates, not Instagram statements [V].
- **Reels ranking predictions (Meta system card, updated 11 Nov 2025):** use the audio; watch less than 3 s (negative); tap Interested; comment; "watch more of a reel than 95% of users who watched reels of the same length"; open a reel from Explore; reshare; share off Instagram; follow the author [P].
- **Hashtags:** capped at 5 per post from Dec 2025; "using fewer (up to 5) more targeted hashtags ... can improve both your content's performance and people's experience" [T]. They label a post; they don't lift reach.
- **Search:** public posts from professional accounts have been indexable by Google and Bing since 10 Jul 2025, so captions and alt text work like page descriptions [T].
- **Carousels:** Buffer (Mar 2026) finds Reels get 36% more reach and carousels 12% more engagement per impression [V]. Practitioners report Instagram re-serves a carousel with a later slide to people who scrolled past it, so slide 2 must also work as a cover [V, not documented by Meta].

### 2.2 Posting

- Cadence: 3 to 5 feed posts a week, Stories about twice a day (Hootsuite, Aug 2026); 3 to 5 posts a week roughly doubled follower growth against 1 to 2 (Buffer, 52M posts) [V].
- Times (local): Thursday 9 a.m., Wednesday 12 p.m. and 6 p.m.; evenings beat mornings on most days (Buffer, 9.6M posts, updated Sep 2026) [V].
- **Trial Reels** (show a Reel to non-followers first) need a professional account and, per Instagram's rollout, about 1,000 followers: not available on day one [P/V].
- Pin up to 3 posts to the top of the grid [V].

---

## 3. X

### 3.1 How ranking works now (open-sourced, Aug 2026 revision)

- One transformer ("Phoenix") predicts probabilities of: favourite, reply, repost, quote, share, **share via DM**, **share via copy link**; clicks on post, profile, link, photo expand, video open; attention: **video quality view**, dwell, dwell time, active seconds; follow author; and negatives: not interested, mute, block, report, **not dwelled**. Final score = Σ weight × probability [P].
- Post-ranking: author-diversity decay, out-of-network discount, **new-author boost** [P].
- Links: X's head of product (Oct 2025) said link posts get lower reach because "the web browser covers the post" and people forget to like or reply, and began testing an in-app browser; he denied links are deboosted [P]. Practitioners still see link posts underperform and move the link to the first reply [V].
- Premium: X Premium tiers get "prioritized rankings" in replies [P, X Help Center "About X Premium" (listing)]. Optional; the kit does not assume it.
- Hashtags: X describes them as indexing for search; practitioners suggest at most two; Musk (Dec 2024): the system "doesn't need them" [T/V].
- Buffer (Mar 2026): text posts had the highest engagement rate on X (3.56%) vs video (2.96%); X engagement rose 44% year on year [V]. **[I]** So X gets both: sharp text one-liners for conversation, native video for the proof.

### 3.2 Posting

- Cadence: 3 to 4 a day (Buffer) or at least 2 to 3 (Hootsuite) [V].
- Times: Tuesday 9 a.m., Wednesday 9 to 10 a.m. (Buffer, 8.7M posts); Tue to Thu 12 to 6 p.m. (Sprout, Nov 2025 to Feb 2026 data) [V].
- One pinned post; header 1500x500 with the avatar overlapping the lower left on web [V].

---

## 4. Threads

- **Ranking predictions (Meta system card, updated 7 Mar 2025):** like; scroll past; click the author's profile (and then another post); click a post; **create a reply**; time spent viewing a post and its permalink [P].
- Follow-graph first since the Nov 2024 rebalance [P]. Links "have been working much better" since mid-2025 (Mosseri) [T].
- **One topic tag per post** ("select a topic that best represents what you're saying") [P, Instagram Help Center].
- Buffer (Mar 2026): video posts engage best on Threads (5.55%) and text-only worst (2.79%); replying to comments lifts engagement most on Threads (+42%) [V].
- Cadence: 1 to 2 a day, or 2 to 3 (Hootsuite) [V]. Times: Thursday 9 a.m., weekday mornings 7 a.m. to 12 p.m. (Buffer, 2.5M posts); Tue to Thu 9 a.m. to 12 p.m. (Sprout) [V].
- Pinned posts are live (a post to your profile, or a reply under your post) [P, Mosseri].

---

## 5. TikTok

- **Recommendation:** interactions (likes, shares, follows, comments, what you create), video information (captions, sounds, hashtags), device and account settings; completion of longer videos is a strong signal; follower count is not a direct factor [P].
- **Eligibility:** unoriginal, watermarked or low-quality content can be made ineligible for For You; the analytics show it and you can appeal [P].
- **Creative:** 9:16, at least 720p, sound on, proposition in the first 3 s, hook in the first 6 s, captions or text overlays, DIY rather than polished, a clear CTA [P, TikTok Ads, Jun 2025].
- Cadence: 2 to 5 a week gave up to 17% more views per post than once a week (Buffer); 3 to 5 a week minimum, daily typical for businesses (Hootsuite) [V].
- Times: Sunday 9 a.m., Monday 1 p.m., Sunday 1 p.m.; 6 to 11 p.m. strong (Buffer, 7.1M posts); Tue to Fri 2 to 6 p.m. (Sprout) [V].
- **Bio link:** needs a Business account or 1,000 followers (reports conflict on whether personal accounts still need 1,000) [V]. Pin up to 3 videos [V].
- **Account type trade-off [I]:** Business gets the bio link on day one and cleared music (CML only, no trending chart sounds). A founder-led personal account can use trending sounds for personal posts, but promotional use of licensed songs is a rights risk. Recommendation: Business account plus original sound.

---

## 6. What got indie and dev tools traction

| Case | What they did | What it says for Farside | Evidence |
|---|---|---|---|
| **Screen Studio** (Adam Pietrasiak) | Daily build-in-public posts on X with product demo clips, at first to "0-2 likes"; one demo went viral after a well-known CEO engaged and "my product launched itself"; "a clear correlation between the count and popularity of my tweets and sales"; X was "by far the biggest source of traffic"; later, dependence on the founder's own profile became the main marketing problem | Real product-in-motion clips on X, posted by the founder, compound. Plan the brand account and the founder account together from day one | [C] Indie Hackers, 31 Jul 2023 |
| **Wispr Flow** (voice dictation) | A creator (UGC) programme that hit "500m views in 60 days": creators got creative freedom for half their posts, the team copied any script that passed 1M views on day one to every creator, and kept a hook library (for example dictating a hard name like "Tchaikovsky" and reacting when it's right); the CEO also onboarded early users personally | Voice dictation is a proven "watch it work" hook; a hook library plus replication beats one-off posts; personal onboarding of the first users | [C] Tanay Kothari on X (2026); Frontlines podcast |
| **Arc** (The Browser Company) | Waitlist with invite codes; unpolished videos that show the engineers and credit community requests; replies and memes on X | A waitlist with invites and "you asked, we built it" videos build a cult; reply to every request | [C] How They Grow; Failory |
| **Raycast** | Built quietly with beta users, launched when there was pull; stuck to YouTube and X; community stories ("What's in my Raycast") | Don't shout before the product is real; spotlight users' setups | [C] Raycast blog; Jeff Morris Jr. |

**[I] Farside's unfair advantages:** a visual metaphor nobody else has (a fingertip and a pointer closing the gap, one ember dot), a deadpan voice already written into the product ("Your Mac is napping", "We won't ask why"), a split-screen proof shot that AI can't fake (thumb on phone, pointer on Mac), and a timely build-in-public story (one person plus AI coding agents). Missing today: real footage. The kit bridges with code-rendered motion; the first real screen recording should replace the "coming" demo beats as soon as the RC build exists (VIDEO-PLAYBOOK.md).

---

## 7. Launching a brand-new account

1. **Before post one:** avatar (the mark), bio with the one-line promise and a CTA, the link (IG bio links; TikTok needs a Business account), a pinned "what is this" post. **[I]**
2. **First 10 posts establish series** people can predict: *Closes the gap* (feature demos), *Status line* (deadpan app copy), *Built with agents* (build in public), *Reach* (brand film moments). Three pinned: the contact video, the "how it works in 3 taps" carousel, and the waitlist post. **[I]**
3. **Post natively, then talk:** reply to every comment in the first hour; on X and Threads, add useful replies under larger Mac, iOS-dev and AI-coding accounts daily (X ranks replies; Threads discovery is reply-driven) [P/V].
4. **Don't delete and repost underperformers** and don't buy followers; use the numbers to pick the next hook. **[I]**
5. **Be honest about status:** no dates, no numbers we can't prove, "coming" for the Anywhere plan, "beta" for agent alerts (PRODUCT.md D28, D29; STORE-LISTING.md claim checklist). **[REPO]**

---

## 8. Open questions and caveats

- Most ranking-weight numbers in blogs are estimates. The only ranking descriptions here that come from the platforms are the Meta system cards, TikTok's newsroom, X's open-sourced code and executives' posts.
- Posting-time studies aggregate other people's audiences; the owner's own analytics override them after two weeks.
- TikTok's Creator Academy and support pages render client-side; quotes from them come via search-result text, so re-read them in the app before relying on the exact wording.
- The waitlist link, the domain (getfarside.com is proposed but not registered) and the trademark opinion are prerequisites for any CTA that points somewhere.
- Handles are not checked (the kit lists candidates only).

---

## 9. How the kit applies this

| Finding | Kit decision |
|---|---|
| <3 s skips are a negative prediction; hook in 3 s | Every video starts mid-motion with the hook at frame 0; no black lead-in |
| Watch past the 95th percentile for the length; replays count | 8 to 15 s loops; the last frames hand back to the first; one 18 s narrative |
| Sends and DM shares drive non-follower reach | Relatable, sendable premises ("send this to the person whose Mac is in the other room") and deadpan status lines |
| Audio reuse is a Reels prediction | Suggest an original named sound; vibe notes point to CML / Meta Sound Collection |
| Originality rules | Clean masters, no watermarks, uploaded natively per platform |
| Captions indexed by search | First caption line = the hook in plain words + "control your Mac from iPhone" |
| Hashtag caps | IG 3 to 5, TikTok 3 to 5, X 0 to 1, Threads 1 topic tag |
| X link handling | Links only in the first reply and bio; the launch thread keeps links to the last post and the reply |
| Carousels re-served by later slides | Slide 2 of every carousel is a second cover that stands alone |
| IG grid crops to 3:4 | Key content inside the centre 1012 px of 4:5 posts and the centre 810 px of 1:1 posts |
| Safe zones | Text box x 65 to 960, y 270 to 1440 on 9:16, checked automatically at render time |
| New account cadence | 14-day calendar: X 2 to 3/day, Threads 1 to 2/day, IG 4 to 5/week, TikTok 4 to 5/week |
| Build-in-public works for dev tools | "Built with agents" series in the calendar; founder account posts alongside the brand |
| AI labels | None needed (code-rendered); label anything generated later |

---

## Sources (retrieved 28 Sep 2026)

Platform primary:
- Meta Transparency Center, Instagram Reels Chaining AI system card (updated 11 Nov 2025): https://transparency.meta.com/features/explaining-ranking/ig-reels-chaining/
- Meta Transparency Center, Threads Feed AI system card (updated 7 Mar 2025): https://transparency.meta.com/features/explaining-ranking/ig-threads-feed/
- Meta Transparency Center, Labeling AI content: https://transparency.meta.com/governance/tracking-impact/labeling-ai-content/
- Instagram for Creators, Rewarding original creators (30 Apr 2026): https://creators.instagram.com/blog/rewarding-original-creators-on-instagram
- Instagram for Creators, Trial reels: https://creators.instagram.com/blog/instagram-trial-reels
- Instagram Help Center, Tag a topic in your post on Threads: https://help.instagram.com/1356090605000312
- Mosseri on Threads, ranking rebalance (Nov 2024): https://www.threads.com/@mosseri/post/DCo4WiOvCB0 ; pinned posts: https://www.threads.com/@mosseri/post/Czop_sbvOfF
- TikTok Newsroom, How TikTok recommends videos #ForYou (18 Jun 2020): https://newsroom.tiktok.com/en-us/how-tiktok-recommends-videos-for-you
- TikTok Newsroom, More ways to spot, shape and understand AI-generated content (19 Nov 2025): https://newsroom.tiktok.com/more-ways-to-spot-shape-and-understand-ai-content?lang=en
- TikTok For You feed eligibility standards: https://www.tiktok.com/safety/en/policies-and-engagement/fyf-standards ; Creator Academy originality policy: https://www.tiktok.com/creator-academy/article/tiktok-originality-policy
- TikTok Ads, Creative best practices (updated Jun 2025): https://ads.tiktok.com/help/article/creative-best-practices
- xai-org/x-algorithm README (Aug 2026 revision): https://github.com/xai-org/x-algorithm
- Nikita Bier (X head of product) on link reach and the in-app browser test (Oct 2025): https://x.com/nikitabier/status/1979994223224209709
- X Help Center, About X Premium: https://help.x.com/en/using-x/x-premium

Trade press:
- Social Media Today, Instagram hashtag limit (18 Dec 2025): https://www.socialmediatoday.com/news/instagram-implements-new-limits-on-hashtag-use/808309/
- Social Media Today, Instagram algorithm insights (Jan 2025): https://www.socialmediatoday.com/news/instagram-shares-algorithm-insights-2025/738034/
- Social Media Today, Threads link posts: https://www.socialmediatoday.com/news/meta-says-link-posts-ranked-properly-threads-reach/750126/
- TechCrunch, Instagram restricts reach of content aggregators (30 Apr 2026): https://techcrunch.com/2026/04/30/instagram-restricts-reach-of-content-aggregators-in-new-crackdown/
- TechCrunch, Threads adjusts its algorithm (21 Nov 2024): https://techcrunch.com/2024/11/21/threads-adjusts-its-algorithm-to-show-you-more-content-from-accounts-you-follow
- TechCrunch, TikTok AI content controls (18 Nov 2025): https://techcrunch.com/2025/11/18/tiktok-now-lets-you-choose-how-much-ai-generated-content-you-want-to-see/
- Exchange4media, X "Made with AI" labels (Mar 2026): https://www.exchange4media.com/digital-news/x-rolls-out-ai-content-labels-as-it-seeks-to-stabilise-advertising-revenue-152469.html
- Instagram posts in Google search from 10 Jul 2025 (PPC Land): https://ppc.land/instagram-content-becomes-searchable-on-google-starting-july-10/

Practitioner studies:
- Buffer, State of Social Media Engagement 2026 (5 Mar 2026, 52M+ posts): https://buffer.com/resources/state-of-social-media-engagement-2026/
- Buffer, How often to post (13 Jan 2026): https://buffer.com/resources/social-media-frequency-guide/
- Buffer, Best time to post on social media (25 Mar 2026): https://buffer.com/resources/best-time-to-post-social-media/ ; Instagram (9.6M posts, updated Sep 2026): https://buffer.com/resources/when-is-the-best-time-to-post-on-instagram/
- Sprout Social, Best times to post 2026 (data Nov 2025 to Feb 2026): https://sproutsocial.com/insights/best-times-to-post-on-social-media/
- Hootsuite, Social media posting schedule (7 Aug 2026): https://blog.hootsuite.com/social-media-posting-schedule/
- Reels length study (Socialinsider, Jan to Jun 2026, via summary): https://www.moonb.io/blog/instagram-reel-length
- Safe zones: Meta Reels 14/35/6 summary https://behaviour.digital/post/meta-reels-safe-zone-14-top-35-bottom-6-sides-the-2026-official-guide ; TikTok ad specs https://admanage.ai/blog/tiktok-ad-specs
- Instagram 3:4 grid: https://www.kapwing.com/resources/instagrams-new-grid-layout-size-and-dimensions-2025/
- Music: https://www.soundstripe.com/blogs/tiktok-music-library-explained ; https://www.velveteen.fm/guides/instagram-for-musicians/music-on-instagram-licensing
- TikTok bio link requirements: https://linklay.io/blog/tiktok-link-in-bio-complete-guide-2026
- X video specs: https://clideo.com/resources/twitter-video-specs

Case studies:
- Screen Studio, "How #buildinpublic brought the first 10 customers" (31 Jul 2023): https://www.indiehackers.com/post/how-buildinpublic-brought-the-first-10-customers-for-screen-studio-and-later-became-the-main-marketing-challenge-ea7c6f0eb1
- Wispr Flow, Tanay Kothari on the UGC programme: https://x.com/tankots/status/2016205317890089273 ; Frontlines podcast: https://www.frontlines.io/podcasts/tanay-kothari/
- Arc: https://www.howtheygrow.co/p/how-arc-grows ; https://newsletter.failory.com/p/lights-camera-arction
- Raycast: https://www.raycast.com/blog/feedback ; https://jmj.medium.com/raycast-built-in-private-157588803d2a
