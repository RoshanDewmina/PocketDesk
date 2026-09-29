> Researched 29 Sep 2026. Read-only: 0 credits spent, nothing bought. Higgsfield balance 615 (Plus plan).

# Higgsfield for Farside launch footage: plan, models, shot budget and labelling (29 Sep 2026)

**I spent 0 credits and bought nothing.** The balance was **615 credits on the Plus plan** when I started and still 615 when I finished. I used only read-only tools: `balance`, `show_plans_and_credits`, `show_credit_reset`, `transactions`, `list_workspaces`, `models_explore`, and `get_workflow_instructions` for `ugc-product-video` and `product-photoshoot`. I did not call `get_cost`, because it lives on the `generate_*` tools.

I kept everything already decided in `Docs/launch/VIDEO-PLAYBOOK.md`:
- Real UI is always captured, never generated.
- Generated footage stays at 25–35% of runtime or less, in shots of 4 s or less.
- Dither goes on in post, and you test the cheapest option first.

The Sep 28 look test (21 credits, 636 → 615) found two things:
- The generated fingertip holds up for 5 s.
- **Under the halftone pass, 480p is enough.** A 1080p finalize "adds nothing visible" (README). The contact sheet confirms this: still 2 reads as a photographed hand once it is dithered.

The biggest cost lever below comes from that second finding.

---

## 1. Account state (from the Higgsfield tools)

| Item | Value | Source |
|---|---|---|
| Plan and balance | Plus, **615** credits, one private workspace | `balance`, `list_workspaces` |
| Next credit reset | About **6 Oct** (earlier resets came on 6 Jul, 6 Aug and 6 Sep, each back up to 1,000). Unused subscription credits don't roll over. On monthly plans they reset at each paid renewal. The next reset after that is about 6 Nov, 11 days before launch. | Playbook transaction history; [Higgsfield help, modified 22 Sep](https://higgsfield.ai/creator-hub/help-center/credits/how-credits-work) |
| `show_credit_reset` | This returned a paid **offer**, not the renewal date: top the balance back up to 1,000 by buying 385 credits, valid until 1 Oct. It's pointless because the free reset comes about 6 Oct. I didn't act on it. | Tool output |
| Recent spend | Only the Sep 28 test (15 + 3 × 2) | `transactions` |

**Plans on offer (widget, USD):**

| | Plus (current) | Ultra |
|---|---|---|
| Credits per month | 1,000 | 3,000 |
| Price | $39/mo billed annually (list $49). The tools show no monthly Plus price. | **$129 monthly**, or $99/mo billed annually |
| Videos / images running at once | 6 / 8 | 8 / 8 |
| Models, resolution | "All models & features". The widget shows no resolution gating on either plan. | Same |
| Commercial rights | Same on every plan (see §5) | Same |
| Storage, scheduled jobs | 2 GB, 2 jobs | 5 GB, 10 jobs |
| Cost per credit | $0.039 | $0.033–0.043. The "70% cheaper" badge isn't borne out by the dollar maths. |

**Top-ups:** 500 for $26, 1,000 for $49, 2,000 for $95, 4,000 for $190. They expire after 90 days. Auto-refill is off; the widget pushes you to turn it on, and I'd leave it off.

**Offers that end tomorrow, 30 Sep (website only, not through the MCP):**
- 7-day unlimited Kling 3.0 at 720p/5 s, on Plus annual and Ultra annual.
- 7-day unlimited Nano Banana Pro 2K, on Ultra.
- 365-day unlimited on several image models.

A year-long commitment just to get these isn't worth it for us.

Some third-party sites say Higgsfield restructured its plans on 14 Aug (Basic/Pro/Max). This account's widget doesn't show that, so trust the widget.

---

## 2. Models that matter to us

The IDs and parameters come from `models_explore` today. **Sora isn't in the MCP catalog.** Higgsfield's own blog says OpenAI shut the Sora app on 26 Apr 2026 and the API on 24 Sep ([source](https://higgsfield.ai/blog/best-ai-video-generators-2026)).

In the credits column, **Exact** means a `get_cost` figure or billing we saw ourselves. **HF blog** means a Higgsfield blog figure, which I'd treat as ±30% ([credits explainer, 8 Sep](https://higgsfield.ai/blog/ai-video-credits-explained)).

| Model | Credits | Length | Start/end frame | 9:16 | Best for us / risks |
|---|---|---|---|---|---|
| `seedance_2_5` | **Exact:** 15 for a 5 s 480p draft; **60** to finalize at 1080p. HF blog: 52 for 8 s at 720p. | 4–30 s | Start and end, plus many references | Yes | Default choice. The draft can be finalized within 7 days. Its hands were stable in our test. It still adds perfect "VFX" rings and lens streaks. |
| `kling3_0` (std/pro/4k, sound off) | HF blog: 10 (720p) and 12.5 (1080p) per 5 s | 3–15 s | Start and end | Yes | Cheapest good motion; best for environments. Output varies from take to take; thumbs sometimes sink into surfaces. |
| `veo3_1` | HF blog: about 58 per 8 s | 4, 6 or 8 s | Start only | Yes | Most believable light and physics. Most expensive, no end frame, and it sometimes adds a finger. |
| `veo3_1_lite` | About 8 per 8 s (low confidence) | 4, 6 or 8 s | Start and end | Yes | Cheap batch. |
| `cinematic_studio_3_0` | HF blog: 25 (720p) or 50 (1080p) per 5 s | 4–15 s | Start and end | Yes | Genre hints, up to 4K. The newer Cinema Studio 4.0 is on the website only. |
| `hf_mult_motion_control` (Genjutsu) | Unknown | Takes its length from the reference video | Reference images plus a reference video | Follows the source | Moves a *real* hand's motion onto a stylized image (the playbook's "machine hand"). |
| `hf_mult_replace_object`, `sync_so` (lipsync), `marketing_studio_video` (UGC/ads) | Unknown | | | | Not for us. The playbook's D10 already rules out AI "creators". |
| Upscale and cleanup: `topaz_video` (1080p/2160p, frame interpolation), `bytedance_video_upscale` (includes `ugc` and `aigc` presets), `video_upscale`, `video_deflicker` | Unknown; check the price first | | | | See 3d. |
| **Images:** `nano_banana_pro` | **Exact:** 2 at 1k/2k, 4 at 4k | | Image references | Yes | Realistic stills and start frames; Higgsfield's product workflow uses this model. |
| `seedream_v5_pro` | 3 | | | | "De-slop" realism pass (Higgsfield's own mandatory step). |
| `gpt_image_2` / `2_5` | 1–11 | | | | Clean flat product mockups. |
| `soul_2`, `soul_cinematic`, `soul_location` | Not priced | | | | People and places. Not needed. |

**Text:** every video model garbles readable text, and Higgsfield's own `ugc-website-video` workflow bans generated UI.

---

## 3. Best tool for each job

**(a) Atmosphere shots (desk at night, Mac glowing far away, dusk, train window)**
- Take the best of 3 `nano_banana_pro` stills.
- Animate it with `kling3_0` at 720p (sound off) or a **`seedance_2_5` 480p draft**, 4–5 s, locked-off camera or a slow push-in.
- Apply the dither in post and don't finalize. The Sep 28 measurements show extra resolution disappears under the pass.
- Save Veo 3.1 and Cinema Studio for the few shots that ship *without* dither.

**(b) A realistic hand holding an iPhone with a green or blank screen**

This is **feasible only for limited "holding" shots**, not for interaction. The risks:
- **The screen plane isn't stable.** Generated phones "breathe": corner radius and bezel drift, and the screen picks up glare or an invented UI. Mentioning a screen at all makes models make one up, which is why Higgsfield's workflow never mentions it.
- **Tracking:** a planar track (Mocha or Resolve) survives small warps over 2–3 s. Tracking needs a **1080p finalize** (60 credits), because a 480p draft doubles the tracking error.
- **Fingers:** fingers near the glass morph, and the phone area stays crisp and un-dithered, so nothing hides the flaws.

If we do it:
- Keep the thumb **off the glass**, so there's nothing to rotoscope.
- Ask for a black, powered-off screen rather than green. Green spills onto the skin; a black screen corner-pins cleanly.
- Keep takes to 2–3 s.

**My recommendation is to shoot this for real.** A tripod, your hand and a phone running the real app cost 0 credits and track perfectly. Only real footage can show a tap that matches the recording. If you want a generated environment, generate only the background and put the real hand and phone over it.

**(c) Hero product-in-scene stills (carousels, thumbnails)**
- `nano_banana_pro` 2k (3 variants), then a `seedream_v5_pro` de-slop pass. Render at 4k if needed.
- Prompt for a generic laptop or phone with no logo, then **composite a real screenshot** onto the screen in post.
- This is the best value for money: about 10 credits per keeper.

**(d) Upscaling or cleaning real iPhone footage**
- Mostly unnecessary: record at native 4K.
- **Never** run screen recordings through `topaz_video` or `bytedance_video_upscale` (`aigc`). Higgsfield's own help says the diffusion-based upscalers "can invent fine detail", which here means your UI text.
- `video_deflicker` might fix refresh-rate flicker when you film a Mac screen with the phone. Test it on a throwaway clip and check the price first.

**(e) Anything that fakes the product UI: stays off-limits.** That covers:
- Generated screens.
- `ad-multiplier` or Seedance `video_edit`, Shorts Studio restyles, and generative upscales on any footage that contains UI.
- AI avatars.

Why: models garble text, Higgsfield's own rule says so, App Store app previews must be in-app captures, and a faked UI misstates the product.

---

## 4. Shot budget

Assumptions: about 3 tries per keeper. Per-keeper costs:

| Shot type | Cheap tier | Medium tier | Premium tier |
|---|---|---|---|
| Atmosphere | ≈36 (6 for stills + 3 × 10 on Kling at 720p) | ≈51 (stills + 3 × 15 Seedance drafts) | ≈170 (Veo or Cinema Studio at 1080p) |
| Hand-with-phone plate | — | ≈117 (12 for 6 stills + 45 for drafts + 60 finalize) | ≈190 |
| Still | ≈9 | ≈10 | ≈25 (4k, alternate models) |

| Tier | Contents | Credits (+15% contingency) | Funding | Extra cash |
|---|---|---|---|---|
| **Cheap** | 20 atmosphere; hand plates shot for real; 1 generated hand-plate test (about 60); 15 stills | ≈915 → **≈1,050** | 615 now + the ~6 Oct reset | **$0** |
| **Medium (recommended)** | 30 atmosphere (8 finalized at 1080p for un-dithered or 16:9 use, +480); 5 generated hand plates as backup to the real shoot; 30 stills | ≈2,895 → **≈3,330** | 615 + 1,000 (Oct) + 1,000 (Nov) = 2,615, plus one 1,000 top-up | **$49** |
| **Premium** | 40 atmosphere, 10 hand plates, 50 stills, about 10 upscales | ≈10,200 → **≈11,700** | Ultra monthly for Oct and Nov + about 5,000 in top-ups | **≈$500** |

Kling, Veo and Cinema Studio prices are ±30% until checked with `get_cost` (free, and the first step of any session that generates).

- **Stay on Plus.** Ultra only makes sense for the premium tier, and under the dither the premium quality mostly doesn't show.
- **Spend the 615 before about 6 Oct.** They expire either way, so that's the atmosphere pilot.
- **Don't finalize the Sep 28 draft** (60 credits, deadline about 5 Oct), as its README advises.

---

## 5. Commercial use and AI labelling

**Commercial use:**
- You own what Higgsfield generates, commercial use is allowed on every plan, and paid plans have no watermark.
- Higgsfield keeps a licence to train on your content until you delete it, so don't upload anything private. ([Help center, modified 12 Sep](https://higgsfield.ai/creator-hub/help-center/account/who-owns-my-generations-and-can-i-use-them-commercially))
- Purely AI-generated footage likely has no US copyright protection ([USCO](https://www.copyright.gov/ai/)). Your edit and the dither pass add the human authorship.

**Platform labels:**

| Platform | What it requires | For our hybrid cuts |
|---|---|---|
| **TikTok** | An AIGC label on realistic AI scenes; it auto-labels from C2PA metadata; ads need an AI disclosure; business accounts must use the Commercial Music Library ([newsroom](https://newsroom.tiktok.com/en-us/new-labels-for-disclosing-ai-generated-content)) | Turn the label on |
| **YouTube** | Disclosure for realistic synthetic footage. It names "AI generated extra footage of a real place" explicitly. Thumbnails count as production assistance and are exempt. Since May 2026 it auto-labels, and on Shorts the label is an overlay on the video. ([help](https://support.google.com/youtube/answer/14328491)) | Tick "altered/synthetic"; AI thumbnails are fine |
| **Meta** (IG, Threads) | An "AI info" label, read from C2PA/IPTC metadata; the disclosure tool is required for photorealistic video ([transparency](https://transparency.meta.com/governance/tracking-impact/labeling-ai-content)); ads get labelled too | Self-label Reels, and carousels that contain AI stills |
| **X** | A "Made with AI" toggle since March 2026; the manipulated-media policy applies ([Techweez](https://techweez.com/2026/03/02/x-rolls-out-made-with-ai-label/)) | Low risk; label anyway for consistency |

Higgsfield reportedly signs its files with C2PA ([RAIW](https://raiw.cc/ai-watermark-checker)), and Veo adds a SynthID watermark. The ffmpeg dither re-encode drops that metadata, so platforms may not auto-label, but **you still have to label**.

The real UI, your real hand and real B-roll aren't AI. Consider a deadpan caption such as "App footage is real. The weather isn't." It turns the label into proof.

**Recommendation:** the medium tier on Plus, run in stages around the resets. Film the hand and phone, and all interaction, for real. Use Higgsfield only for dithered atmosphere (Kling or Seedance drafts) and composited stills. Label every post that contains a generated plate.

---

## Sources

**Higgsfield MCP (live tool output, 29 Sep 2026):** `balance` (615, plus, read at start and end), `show_plans_and_credits`, `show_credit_reset`, `transactions`, `list_workspaces`, `models_explore` (list, get, search, recommend), `get_workflow_instructions` (catalog, `ugc-product-video`, `product-photoshoot`).

**Local:** `~/Developer/PocketDesk/Docs/launch/VIDEO-PLAYBOOK.md` (28 Sep); `~/Downloads/farside-video-test/README.md`, `contact-sheet_stills.png`, `pass-tests.png` (Sep 28 look test).

**Higgsfield web:**
- [How credits work (modified 22 Sep 2026)](https://higgsfield.ai/creator-hub/help-center/credits/how-credits-work)
- [Who owns my generations / commercial use (modified 12 Sep 2026)](https://higgsfield.ai/creator-hub/help-center/account/who-owns-my-generations-and-can-i-use-them-commercially)
- [AI video credits explained (modified 8 Sep 2026)](https://higgsfield.ai/blog/ai-video-credits-explained)
- [Best AI video generators 2026 (modified 3 Sep 2026)](https://higgsfield.ai/blog/best-ai-video-generators-2026)
- [Credits vs unlimited](https://higgsfield.ai/blog/credits-vs-unlimited-ai-video-generation)
- [AI video upscaler](https://higgsfield.ai/ai-video-upscaler)

**Platforms:**
- [TikTok: new labels for disclosing AI-generated content](https://newsroom.tiktok.com/en-us/new-labels-for-disclosing-ai-generated-content)
- [YouTube: disclosing altered or synthetic content](https://support.google.com/youtube/answer/14328491)
- [YouTube auto-labels (TechWyse, May 2026)](https://www.techwyse.com/news/platform-updates/youtube-automatic-ai-labels-disclosure-may-2026)
- [Meta Transparency Center: labeling AI content](https://transparency.meta.com/governance/tracking-impact/labeling-ai-content)
- [Meta AI labels in ads (Coinis, 2026)](https://coinis.com/blog/meta-ai-content-labeling-facebook-instagram-ads-2026)
- [X "Made with AI" label (Techweez, Mar 2026)](https://techweez.com/2026/03/02/x-rolls-out-made-with-ai-label/)

**Other:**
- [RAIW: AI watermark checker (C2PA signers incl. Higgsfield)](https://raiw.cc/ai-watermark-checker)
- [US Copyright Office: copyright and AI](https://www.copyright.gov/ai/)
- [Krea: Higgsfield pricing (third party)](https://www.krea.ai/blog/higgsfield-pricing-explained-2026-unlimited-credits-and-real-monthly-costs)
- [Kling 3.0 credit guide (Kling, third party to Higgsfield)](https://kling.ai/blog/kling-video-3-0-credit-cost-guide)
