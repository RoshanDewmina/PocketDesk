# Farside video playbook: website hero loop and social promos

Prepared 28 September 2026 (research and plan only). **No Higgsfield generation was run and no credits were spent.** Balance read at the start of the research: **636 credits** (plan: Plus). Re-read at the end: **636, unchanged**.

Scope: (1) a full-bleed, dark, 6 to 12 s seamless hero loop that works behind text; (2) fast, engaging 9:16 promo videos (15 s, 30 s, 45 s) with 16:9 and 1:1 cutdowns that look real and not AI-generated. Brand direction: dithered, halftone, dystopian-deadpan, cinematic (`design/farside-round1/DITHER-BRIEF.md`).

## Evidence tags

Every claim carries a tag so Higgsfield-documented facts stay separate from practitioner heuristics.

| Tag | Meaning |
|---|---|
| **[HF-MCP]** | Read from the Higgsfield MCP tools on 28 Sep 2026. Authoritative for model IDs, parameter names, plan and balance. |
| **[HF-WF]** | Higgsfield workflow files served by the MCP (ugc-website-video, ad-multiplier, character-sheet, video-editing). |
| **[HF-WEB]** | Higgsfield's own site or blog (dated in section 9). |
| **[OBS]** | Observed in this account's transaction history. |
| **[3P]** | Third-party page (linked in section 9). Vendor blogs are marketing; treat numbers as indicative. |
| **[HEUR]** | Practitioner heuristic. Repeated in several sources but not verified by Higgsfield or by me. |
| **[MEAS]** | Measured by me locally with ffmpeg 9.0.2 on a synthetic 10 s 1080p24 gradient clip. Re-measure on real footage. |
| **[APPLE]** | Apple primary documentation. |
| **[REPO]** | Farside repository docs (`PRODUCT.md`, `Docs/launch/STORE-LISTING.md`). |
| **[INFER]** | My judgment. Challenge it. |

---

## 0. The plan in one screen

1. **Anything that shows UI, a screen, text, a logo, or fingers on glass is captured for real, never generated.** Higgsfield's own UGC workflow bans generated UI outright, on the grounds that video models render UI text as gibberish [HF-WF]. Farside's promise is "it just works", so the screens must be the actual app.
2. **Higgsfield's job is atmosphere:** empty environments, weather, light, a void, a doorway. These are the strongest area for current models and carry no hands, faces or text. Keep generated footage to about 25 to 35 percent of runtime, in shots of 4 s or less [INFER].
3. **The brand look is a deterministic post pass, not a prompt.** Prompting "dithered" gives noise, not a dot screen. Generate clean low-key footage, then apply a Bayer (ordered) dither or halftone in post. Ordered dither is temporally stable and cheap to encode; error diffusion shimmers and is about 7.5 times larger [MEAS] (section 6.7 and Appendix A have tested commands). The dither also masks the AI sheen.
4. **For the "Reach" concept, the most real answer needs no AI:** film the owner's real hand on black and halftone it. Higgsfield adds value only if we want a "machine hand" (via the Genjutsu motion-transfer model) or atmospheric B-roll. Likewise the "Transmission" hero can be made entirely from a real screen recording at 0 credits.
5. **Cheapest first test: about 21 to 45 credits (roughly $1 to $2)**, plus one zero-credit dither test on real footage. Details in section 6.6.
6. **Budget:** lean path about 215 credits (280 with 30% contingency, about $14); full path about 850 (1,100 with contingency, about $55). The account holds 636 and, on the observed pattern, will be reset to 1,000 on about 6 Oct [OBS]. Both paths fit if staged around that reset (section 2.4). Every figure is plus or minus 30% until `get_cost` confirms it.
7. **Do not print "17 November" on any creative until the 2 Nov go/no-go** [REPO], and gate every "anywhere" and "agent needs you" shot on what the release-candidate build actually does (section 8).

---

## 1. Decisions needed from the owner

| # | Decision | Recommendation | Why |
|---|---|---|---|
| D1 | Approve the stage-0 test (about 30 credits) | Yes | Answers the only real unknown: does the generated plate survive the dither pass and read as intentional? |
| D2 | Hero concept family | Decide after the test. My ranking for video: **Transmission** (0 credits, real UI), **Reach** (real hand plus procedural cursor), **Overgrown** (pure generative, best use of Higgsfield), **Afterglow** (riskiest: face plus phone glow) | `PRODUCT.md` D31 says Higgsfield generation waits for a chosen concept |
| D3 | Launch date on creatives | Use "This November" until the 2 Nov go/no-go | 17 Nov is proposed and conditional [REPO] |
| D4 | "Anywhere / from any network" in videos | Show only if Farside Remote is live in the RC build; otherwise say "Free on your Wi-Fi" | Relay and signaling were not deployed on 28 Sep [REPO] |
| D5 | "Agent needs you" alert on screen | Capture the real push on the RC build, or leave the 15 s cut for later | Ships as beta (D29); a staged fake alert would misstate the product |
| D6 | The brief's own voice line "Your Mac is on the far side. You're not." (and the `22-far-side` concept name) | Prefer "Your Mac is over there. You're not." in video copy. Get counsel's view first | The listing notes flag THE FAR SIDE mark (US Reg. 6255846, live) and say never write "Far Side" in copy, keywords or URLs [REPO] |
| D7 | Music | Licensed track with cross-platform rights, or sound design only | TikTok's business library covers TikTok only [3P] |
| D8 | Voice | Owner's own deadpan voice-over recorded on a phone, or captions only | Real beats synthetic for believability; Higgsfield TTS exists as a fallback |
| D9 | Editor | Whatever you already own (Final Cut, Resolve, CapCut). The pipeline is app-agnostic; ffmpeg does the dither | |
| D10 | AI "creator" UGC avatars (Marketing Studio) | **No** | Most detectable form of AI video, must be disclosed, and clashes with the brand [INFER] |

---

## 2. Higgsfield account state and pricing

### 2.1 Account [HF-MCP, 28 Sep 2026]

- Balance **636 credits**, plan **Plus**, one private workspace (`f743f4f3-c983-4772-8505-3e8cd75fa310`, role owner).
- One project/folder: "New folder", `folder_id` `1996effd-7ac7-41c1-af5b-2e7ad8d67886`. No Soul characters and no reference Elements exist yet, so there is no reusable identity or style asset to inherit.
- The free MCP trial converted on 6 Jul 2026 (100 trial credits); `unlim.available` is false today, so nothing is free.
- Plan facts (widget; third-party pages quote $47 to $49 and 1,000 to 1,200 credits for Plus, so trust the widget and the billing page): Plus is 1,000 credits per month at $39 per month billed annually; Ultra is 3,000 credits per month at $99 (annual) or $129 (monthly). Parallel generation: 6 videos and 8 images on Plus. Top-ups: 500 credits $26, 1,000 $49, 2,000 $95, 4,000 $190; top-ups expire after 90 days; auto-refill is disabled.
- Time-sensitive: the widget lists unlimited-generation promotions "buy until Sep 30", flagged "available on web". Third-party notes say unlimited offers do **not** apply through MCP, CLI or Canvas [3P Krea]. At our volume (about 50 stills) they are irrelevant; noted only because the date is two days away.
- Value of a credit: Higgsfield prices Seedance 2.5 at 30 credits for $1.50, so **1 credit is about $0.05** [HF-WEB]; top-ups work out to $0.0475 to $0.052.

### 2.2 Cost table (credits). Read before budgeting.

The MCP does not expose a price list. `generate_video`, `generate_image` and `generate_audio` accept **`get_cost: true`, documented as returning the cost without submitting any job** [HF-MCP tool schema]. I did not call it because it sits on a `generate_*` tool and this task forbids those. **First action of whoever executes this plan: preflight every planned generation with `get_cost: true`.** Until then use the ranges below.

| Model and setting | Credits | Source | Confidence |
|---|---|---|---|
| Seedance 2.5, 480p (draft), 10 s | 30 (about 3 per second); 8 s = 24 | HF-WEB (19 Sep) and 3P Picsart | Medium-high |
| Seedance 2.5, 720p, 8 s | 52 | HF-WEB (6 Aug) | High |
| Seedance 2.5, 720p, 10 s | 70 | HF-WEB (19 Sep) | High |
| Seedance 2.5, 5 s with audio | 33 | web-search snippet (page not identified) | Medium-low |
| Seedance 2.5, 1080p, 8 s | 72 | HF-WEB (11 Sep) | Medium (conflicts with next row) |
| Seedance 2.5, 1080p, 10 s | 120 | HF-WEB (19 Sep) | Medium (implies 12 per second vs 9 per second above; **budget 12 per second**) |
| One Seedance 2.5 job on this account | 252 | OBS, 7 Sep (settings not exposed) | n/a |
| Kling 3.0, 5 s, 720p / 1080p | 10 / 12.5 | 3P Krea (verified 31 Aug) | Medium |
| Kling 3.0, 8 s, 1080p | 20 | HF-WEB (11 Sep) | Medium-high |
| Kling 3.0, 10 s, 720p / 1080p | 20 / 25 | 3P Krea | Medium |
| Seedance 2.0, 5 s, 720p / 1080p | 23 / 45 | 3P Krea | Medium |
| Cinema Studio (version unspecified), 5 s, 720p / 1080p | 25 / 50 | 3P Krea | Medium-low |
| Veo 3.1, per clip | 40 to 70 | HF-WEB (blog, updated 29 Aug) | Medium-low |
| Veo 3.1 Lite, 8 s | 8 silent, 12 with audio | web-search snippet (page not identified) | Low |
| FLUX 3 Video Edit | 1 per processed second (max 15 s) | HF-MCP model description | High |
| Nano Banana Pro still | 2 (1k/2k), 4 (probably 4K) | OBS and 3P Krea | High for 2 |
| GPT Image 2.0 still | 1 (low, 1k) up to 11 (higher tiers) | OBS (settings inferred) | Medium |
| Seedream 5.0 Pro still | 3 | OBS | High |
| Seedance 2.0 Mini job | 10 | OBS, 3 Jul (settings not exposed) | n/a |
| Cinematic Studio Video V2 job | 18 | OBS, 3 Jul | n/a |

Rules that apply on Higgsfield: credits are deducted for every generation including re-rolls and upscales; a Nano Banana Pro job was refunded once in the history [OBS], so failures can be refunded but do not assume it.

### 2.3 What the MCP can and cannot do

- **Cinema Studio 4.0 (30 s clips, up to 50 references, emotion console, lighting console, video extend) launched 12 Aug and is a website product; the MCP still exposes Cinema Studio Video 3.0** (`cinematic_studio_3_0`) [HF-WEB, HF-MCP]. Searching the MCP catalog for "cinema studio 4.0" returns nothing.
- **There is no music or general SFX generation.** `sonilo_music`, `mirelo_text_to_audio` and `inworld_text_to_speech` are flagged "game pipeline only" and the tool description says to decline standalone music and SFX requests [HF-MCP]. Native audio comes only inside video models (`generate_audio`). Speech: `seed_audio`, `elevenlabs_v4`, `qwen_audio_tts`, `text2speech_v2`.
- **No frame-accurate editor via MCP.** A sandbox (`sandbox_exec`, ffmpeg, Playwright) and a Higgsedit CLI workflow exist [HF-WF], but I recommend finishing locally (section 6.7).

### 2.4 Use-it-or-lose-it credits [OBS + 3P]

The history shows "Subscription Credits Reset" (deduct) followed by "Subscription Credits" (+1,000) at about 03:15 UTC on the **6th of July, August and September** (September: minus 972.25, then plus 1,000). A third-party pricing review states subscription credits reset at renewal and do not roll over [3P Krea]. **Expect the 636 credits to be replaced by 1,000 on about 6 Oct 2026.** So: any test or library work approved before 6 Oct costs nothing extra; from 6 Oct a fresh 1,000 arrives. Two things to check on the Higgsfield billing page before relying on this: the exact renewal instant, and whether any balance is top-up credit (top-ups keep 90 days).

---

## 3. Higgsfield capabilities today

### 3.1 Video models on the MCP (exact IDs and parameters) [HF-MCP unless noted]

Media roles are the `role` values in `medias[]`. Where a model lists both `start_image` and `end_image`, it can be used for loops.

| `model` | Duration | Resolution / options | Aspect ratios | Media roles | Notes and strengths |
|---|---|---|---|---|---|
| `seedance_2_5` | 4 to 30 s | `resolution` 480p/720p/1080p; `mode` `t2v`, `omni_reference`, `video_edit`, `video_extension`; `generate_audio`; `bitrate_mode` standard/high; **`draft`** (480p draft finalizable within 7 days) and `draft_job_id`; `extension_mode` | auto, 21:9, 16:9, 4:3, 1:1, 3:4, 9:16 | start_image, end_image, image_references, video_references, audio_references | Up to 50 references, audio generated in the same pass [HF-WEB]. Draft-then-finalize is the cheapest iteration loop. Default video model in tool guidance. |
| `seedance_2_0`, `seedance_2_0_mini` | 4 to 15 s | `mode` std/fast (Mini: 480p/720p only); `genre`; `generate_audio`; 4k on std | auto, 16:9, 9:16, 4:3, 3:4, 1:1, 21:9 | same as above | Flagged `supports_unlim`; Mini is the budget variant. |
| `kling3_0` | 3 to 15 s | `mode` std/pro/4k; `sound` on/off ("off" lowers credits) | 16:9, 9:16, 1:1 | start_image, end_image | Multi-shot, audio sync, motion transfer, cheapest per second among premium models. Best for physical motion [3P]. |
| `kling3_0_turbo` | 3 to 15 s | 720p/1080p | 16:9, 9:16, 1:1 | start_image | Fast/budget. |
| `cinematic_studio_3_0` | 4 to 15 s | 480p to 4k; `genre` auto/action/horror/comedy/noir/drama/epic; `generate_audio` (default off) | auto, 21:9, 16:9, 4:3, 1:1, 3:4, 9:16 | image, start_image, end_image | Higgsfield's top cinema-grade tier; virtual camera rig, 9 references, 8 speed-ramp presets on the web tool [HF-WEB]. |
| `cinematic_studio_video_v2` | 3 to 12 s | `mode` pro/std; `genre`; `speedramp`; `multi_shots` + `multi_prompt`; `cfg_scale`; `sound` | 1:1, 4:3, 3:4, 16:9, 9:16 | image, start_image, end_image | Refined camera and colour. |
| `veo3_1` | 4/6/8 s | `quality` basic/high/ultra; `variant` veo-3-1-fast / veo-3-1-preview | 16:9, 9:16 | start_image only | Top realism for environments and light, strong native audio, 8 s ceiling [HF-WEB, 3P]. |
| `veo3_1_lite` | 4/6/8 s | `generate_audio` (default false) | 16:9, 9:16, auto | start_image, end_image | Cheap batch clips. |
| `gemini_omni_flash_1_1` | 3 to 10 s | `mode` text-to-video / image-to-video / reference-to-video / edit; 360p to 4K | 16:9, 9:16 | start_image, end_image, image_references, video_references | Released 27 Aug; independent tests report weaker lip sync and motion realism [3P]. |
| `minimax_h3` / `minimax_h3_max` | 4 to 15 s / 5 to 15 s | 2K / 480p-768p; `batch_size` 1 to 4 | auto, 21:9, 16:9, 4:3, 1:1, 3:4, 9:16 | start/end, image, video, audio references | Strong motion realism and 2K output; Max is the fast tier [3P]. |
| `flux_3_video` | 5 to 20 s | 720p/1080p; audio | auto, 21:9, 2:1, 16:9, 4:3, 1:1, 3:4, 9:16 | start, end, image and video references | Strong facial expression and sound-to-physics [3P]. |
| `grok_video_v15` | 2 to 15 s | 480p/720p/1080p | (none listed) | start_image, image_references, audio_references | Preview. |
| `wan3_0`, `wan3_0_prime`, `wan2_7` | 2 to 30 s / 2 to 15 s | 480p to 1080p; native audio | 16:9, 9:16, 1:1, 4:3, 3:4 | first/last frame, references | Cheaper; stylized. |
| `hf_mult_motion_control` ("Genjutsu") | n/a | 480p/720p/1080p | (source) | image_references + video_references | **Transfers motion from a reference video onto subjects in reference images.** Relevant: our real hand motion onto a stylized "machine hand" image. |
| `hf_mult_replace_object` | n/a | 480p to 1080p | (source) | image + video refs | Replace an object in a source video. |
| `marketing_studio_video` | 12 to 15 s | 720p/1080p; `mode` preset slug; avatars, products, hooks | up to 21:9 | avatars, medias | UGC and product ads. Not recommended for Farside (D10). |

Post tools on the MCP: `topaz_video` (1080p/2160p), `bytedance_video_upscale` (1080p/2k/4k with an `aigc` preset), `video_upscale`, **`video_deflicker`**, `fps_boost` (16 to 120 fps), `sam_3_video` (remove background), `depth_anything_video`, `reframe` (change aspect), plus video editors `seedance_2_5` (`video_edit`), `kling_video_edit`, `flux_3_video_edit`.

### 3.2 Image models (stills, start frames) [HF-MCP]

| `model` | Options | Use here |
|---|---|---|
| `gpt_image_2_5` (default general model in tool guidance) | `variant` flare/sunburst; `quality` low/medium/high/xhigh/max; `resolution` 1k/2k/4k; `background`; many aspect ratios incl. 21:9, 9:16 | Photoreal stills, typography, edits |
| `nano_banana_pro` (also `nano_banana_2`, `nano_banana_2_lite`) | `resolution` 1k/2k/4k; `image_references` | Cheap realistic stills (2 credits [OBS]); text and diagram strength |
| `soul_cinematic` / `soul_2` | `quality` 1.5k/2k; `soul_id` (trained identity works only with these two) | Cinematic concept stills; UGC-style portraits |
| `cinematic_studio_2_5` | 1k/2k/4k; 21:9 | Cinematic stills |
| `seedream_v5_pro` / `seedream_v5_lite` / `seedream_5_0_flash` / `seedream_v4_5` | `resolution`; `image_references`; editing | The **de-slop pass** used in Higgsfield's own workflow (below) |
| `flux_2`, `kling_omni_image`, `openai_hazel` (best text rendering), `recraft_v4_1` (vector/logos), `grok_image(_2_0)`, `z_image` (0.15 credits [OBS]) | | Variants |

Upscalers: `topaz_image`, `topaz_image_generative`, `bytedance_image_upscale`. Outpaint: `outpaint`, `flux_2_pro_outpaint`.

### 3.3 Workflows worth knowing (`get_workflow_instructions`, no argument) [HF-WF]

| Workflow | What it does | Use for Farside? |
|---|---|---|
| `ugc-website-video` | Talking-head AI creator plus **real captured screenshots** overlaid as cards; hard rules: never AI-generate UI, never animate a screenshot | Only as a source of documented practice. Not the format (AI creator, web-page capture, D10) |
| `ad-multiplier` | Silent video edits of one 4 to 30 s source into N variants via `ad_multiplier` (Seedance 2.5 `video_edit`, source audio re-attached in ffmpeg) | **Not on footage containing real UI** (regenerating pixels can alter text) [INFER]. Possible later for B-roll-only variants (time of day, location) |
| `character-sheet` | Slot-based prompts with an "unretouched / anti-AI" realism engine | Only if a recurring character is added. Its realism clauses are reused in 4.3 |
| `video-editing` (Higgsedit) | Scripted timelines, captions, native graphics, render in a sandbox | Optional; local editor preferred |
| `subtitles` | Burns Whisper-timed captions into pixels | Optional; local editor preferred |
| `narrator`, `faceless-video`, `thumbnail-generation`, `product-photoshoot`, `brand-asset-creation`, `website-builder-flow` | See catalog | Not needed |

Other tools: **Marketing Studio motion presets** (231 in the catalog) include "Halftone Street Collage", "Pixel Block Yard", "90s Bedroom CRT", "Monospace Callouts", "Echo Wave" [HF-MCP, browse only]. They animate a supplied product image. Worth one cheap experiment after the concept is chosen; quality and cost unknown. **Shorts Studio** restyles a supplied video toward a style preset and lets you create your own preset; restyling would destroy UI text, so live-action B-roll only. `virality_predictor` and `video_analysis_create` exist; I did not evaluate them.

### 3.4 Consistency, lip-sync, avatars, presets [HF-MCP]

- **Soul characters** (`show_characters`): train from 5 to 20 photos in about 10 minutes; usable **only** with `soul_2` and `soul_cinematic`; one soul per generation. **Reference Elements** (`show_reference_elements`): instant, one image is enough, several per generation via `<<<UUID>>>` in the prompt; work with Nano Banana Pro/2, GPT Image 2, Seedream 4.5 and 5 lite, Cinema Studio Image 2.5, Cinema Studio Video 2 and 3.0, Seedance 2.0 and Kling 3.0. This account has neither. **Farside needs neither in v1**: the plan has no recurring generated person.
- **Lip-sync:** `sync_so` ("Sync Lipsync 3": `input_video` plus `input_audio`, `sync_mode` bounce/loop/cut_off/silence/remap); `dubbing`, `voice_change` and `create_voice` also exist. Not needed if the voice-over is off-camera.
- **Talking avatars and UGC:** `marketing_studio_video` with at most one avatar, hooks and settings. Not recommended (D10).
- **Presets:** a catalog of about 60 product recipes (for example `push-in`, `pull-back`, `whip-pan`, `hero-shot`) and Marketing Studio motion presets; built for physical products, of little use for software. **Shorts Studio** style presets exist (Bold Urban, Green Contrast, Urban Serenity, Warm Glow, Yellow Frame, Monochrome Vibes, Claymation, Marker Scribble and more) and you can create your own.
- **Also on the MCP, not evaluated:** TikTok connect, prepare-publish and publish-status tools (publishing needs the owner's account and explicit approval in any case); a website builder; 3D generation.

### 3.5 Parameter cheat sheet [HF-MCP tool schemas]

- `generate_video` / `generate_image` take one object: `{"params": {...}}`.
- Common: `model` (required), `prompt`, `aspect_ratio`, `duration` (int seconds), `count` 1 to 4 (variants of the same prompt; cost multiplies), `folder_id`, `medias` = `[{"value": "<media_id or job_id>", "role": "start_image"}]`, `get_cost`, `use_unlim`.
- Model parameters are **top-level** (for example `resolution`, `mode`, `generate_audio`, `sound`, `draft`, `draft_job_id`, `quality`, `variant`).
- `medias[].value` must be a media UUID or a prior job ID, never a URL. Upload path: `media_upload` then PUT bytes then `media_confirm`, or `media_import_url`. Independent prompts go through `generate_video_batch` / `generate_image_batch` (2 to 12), then `jobs_wait`.
- On a rejected combination the server returns `adjustments` and a `recovery_tool`; apply them. On a transport timeout do not resubmit blindly.
- The exact call shape for finalizing a Seedance 2.5 draft (`draft_job_id`) is not spelled out beyond the parameter descriptions; confirm with `get_cost` before paying.

---

## 4. Making it look real

### 4.1 Hard rules

1. **Real capture for UI, text, logos and fingers on glass.** Higgsfield's own workflow says the screen must always be real captured pixels, and a body clip must not even mention a screen, or the model invents a fake one [HF-WF]. Its clip prompts carry an exclusion line for every shot; we reuse the idea in our own words: no website, no app UI, no screen or rendered content on any device anywhere in frame.
2. **Environments, light and weather from Higgsfield; humans and devices from a camera.** Higgsfield's character rules warn that creative body poses are an anatomy gamble: extended limbs warp and foreshortened hands grow extra fingers [HF-WF].
3. **Short inserts.** Generated footage held for 2 to 4 s at pace reads as B-roll; long generated takes invite scrutiny [3P, HEUR].
4. **One unifying finish over everything** (grade, grain, dither on generated plates, sound). Match the realism level of the generated shots to the real ones [3P, HEUR].
5. **Sound sells realism.** Without real room tone, foley and ambience, even good video "will feel fake" [3P, HEUR].

### 4.2 What will still look AI: shot risk table

Model performance on hands varies by model and has improved through 2026 (Seedance 2.0 rated best, Kling 3.0 occasionally sinks a thumb into a surface, Veo 3.1 sometimes adds a finger) [3P]. Text and logo weakness is corroborated by Higgsfield's workflow files and by the Seedance guide's negative constraint "No logos, no readable text" [HF-WF, HF-WEB].

| Shot | Verdict | Why | Do this instead |
|---|---|---|---|
| Phone or Mac screen showing anything | Red | Gibberish UI text; fake UI [HF-WF] | Real capture; if a generated device must show a screen, composite the real recording with a corner pin (locked-off shot) |
| Thumb or finger on a phone screen | Red | Contact physics, finger count | Owner films it; or halftone macro at 18 px dot pitch or coarser, which masks errors |
| Hands typing | Red | Many fingers in fast motion | Cut to the screen |
| Talking face in close-up | Red | Uncanny, lip sync, must be labelled | Owner on camera, or no faces |
| People at distance, silhouettes, backs | Amber | Fine under dither | Use sparingly |
| Logos (Apple logo on laptop or phone, agent brand UIs) | Red | Malformed logos; trademark | "no logos" in the prompt; tape the lid logo on real shoots; use a generic agent prompt on screen |
| Signs, keyboards, labels, readable text | Red | Garbled | Add text in post |
| Empty rooms, doorways, weather, light, dust | **Green** | Strongest generative area | Use |
| Slow push-ins, drifts, locked-off shots | **Green** | | Use |
| Object macro without hands (phone face-down) | Green/amber | Device shape mostly fine | Say "no logo", static camera |
| Same device in several generated shots | Amber | Drift | Show it once, or reference the same start still |
| Seamless loop from identical start and end frames | Amber | Most models give little or no motion when both frames are identical [3P] | Two-half method (section 6.2) |
| Clips over 8 s | Amber | Drift; Veo ceiling is 8 s [3P] | Cut at 3 to 5 s |

### 4.3 Prompt craft

**Structure (Higgsfield's Seedance 2.5 guide)** [HF-WEB]: labelled sections in one text block, which the guide says beat a single run-on paragraph: GLOBAL STYLE, SCENE, CHARACTERS, LOCATION, FIRST FRAME AND BLOCKING, SHOT-BY-SHOT, OPTICS, CAMERA, PHYSICS, LIGHTING, AUDIO. Other documented specifics: pin the exact first visible frame; state focal length and camera height per shot; lock the lens so it does not drift mid-clip; describe handheld as a human operator breathing and correcting rather than a smooth drone glide; write diegetic audio and list exclusions (no music, narration or subtitles) explicitly.

**Realism language (Higgsfield's own)** [HF-WEB, HF-WF]:
- Texture vocabulary: light 35mm grain, gentle gate weave, halation on highlights, a battered lived-in photochemical feel.
- Anti-slop negatives the guide uses: not a clean CGI render, not plastic or glossy-synthetic, no beauty retouch or digital smoothing, no logos, no readable text.
- Skin (character-sheet workflow): keep pore-level texture, no beauty filter, no airbrushed look.
- Phone-camera look (for any real-person UGC still): sensor grain, slightly imperfect framing, and a hard ban on studio or editorial phrasing (editorial, flawless or glowing skin, poised, fisheye) [HF-WF ugc-character]. Lighting: cool neutral daylight; golden hour and warm casts read as stock advertising [HF-WF].
- De-slop image pass used in Higgsfield's workflow: `seedream_v5_pro`, `resolution: "2k"`, the source image as `image_references`, with the instruction to keep composition and identity and change only micro-realism (pore-level texture, faint sensor noise, no HDR glow, no bokeh, no teal-orange grade) [HF-WF ugc-website-video step 3.5]. Cost about 3 credits [OBS].

**Camera vocabulary (Veo 3.1 guide)** [3P, Google Cloud, 15 Oct 2025]: formula `[Cinematography] + [Subject] + [Action] + [Context] + [Style and Ambiance]`; lens and film-stock cues (35mm with natural grain, 16mm documentary look); handheld phrased as the shake of a phone or camcorder; dialogue in quotation marks, `SFX:` and `Ambient noise:` for sound.

**Farside global style block** (paste into every generated shot) [INFER, assembled from the documented pieces above]:

> GLOBAL STYLE: Low-key, near-black ground, one practical light source, a single sodium-ember accent against cool neutral shadows. Authentic 35mm film photography, natural grain, gentle halation on highlights, slight lens softness, matte unretouched lived-in surfaces. NOT CGI, NOT plastic, NOT glossy synthetic, no beauty retouch. No logos, no readable text, no UI, no rendered content on any screen.

### 4.4 Post: the real-look finish

| Step | Guidance |
|---|---|
| Grain | The most-cited single realism lever: AI frames have no sensor noise [3P, HEUR]. Suggested strength is subtle (roughly 2 to 3 percent, or an overlay at 20 to 40 percent opacity). **Cost warning:** temporal grain multiplies file size (about 7 times in my test, section 6.7), fine for social, wasteful for the web hero. |
| Softness | A light blur before grain removes the crisp "render" edge [3P, HEUR]. |
| Denoise | Keep it low when upscaling; aggressive denoise gives waxy surfaces [3P, HEUR]. |
| Grade | Grade generated and real footage to one look (ember accent, crushed blacks) so the cut does not jump. |
| Dither | Applied to **generated plates, transitions and the hero only**. Screen recordings stay crisp (brief: "crisp UI text and controls on top"). |
| Screen replacement | For a device in a generated or filmed shot: lock the camera, corner-pin the real recording, add a subtle glass reflection and screen bloom. |

### 4.5 Sound

Build a sound bed that Higgsfield cannot make: room tone per location (record 30 s), finger taps on glass and a real mechanical click for the haptic (foley beats give the edit its rhythm), your own notification chime (do not use Apple's system sounds), a low drone or pad, and the owner's dry voice-over. Loudness target about -14 LUFS integrated for social is a common heuristic [HEUR, unverified].

Music rights: TikTok restricts business accounts to its Commercial Music Library and the licence covers TikTok only; the same clip on Instagram or YouTube can be muted for copyright [3P Soundstripe and others]. For a single cross-platform master use a track licensed for all platforms, or no music.

### 4.6 "Looks real" must not mean "hidden AI"

- **TikTok** requires the AIGC label (organic) or AI Disclosure tag (ads) for realistic AI-generated scenes and people, and reads C2PA credentials to auto-label; a four-tier penalty ladder is described [3P]. **YouTube** requires disclosure of realistic synthetic content and, since May 2026, auto-labels undisclosed photorealistic AI [3P]. **Meta** applies an "AI info" label from metadata and offers "Label this content as made with AI" [3P].
- Plan to label. Do not strip metadata. Atmospheric, dithered B-roll may not need it under each platform's wording, but treat the toggle as cheap insurance and check the current policy on posting day.
- Real UI and owner-filmed footage are not AI; only the generated plates are.

---

## 5. Structure that performs (research summary)

### 5.1 Findings and how sure I am

| Finding | Source | Confidence |
|---|---|---|
| Put the payoff or a bold claim inside the first 2 to 3 s; the first 0.5 s needs something visually or audibly arresting | Several TikTok hook guides [3P] | Medium (secondary blogs) |
| Retention milestones commonly cited: about 70% past 3 s, about 60% at 15 s, about 50% at 30 s | Same [3P] | Low-medium |
| Pattern interrupt every 3 to 5 s (3 to 5 in total for a short); open loops every 10 to 15 s in longer cuts | Same [3P, HEUR] | Medium |
| Sell the outcome rather than the demo: open on the pain, hook in under 5 s, show the after-state; ship five formats from one story (YouTube/site, 9:16, 1:1, silent hero loop 6 to 12 s, email teaser) | Flowjam [3P] | Medium (vendor blog; "3.4x view time" claim is unverifiable) |
| On X, the median startup launch video gets about 28k views; 30.6% pass 100k; 7.9% pass 1M | UGC Scout [3P] | Low-medium |
| Most YC-style launch videos are phone-shot or screen-recorded and win on the problem-first hook and a clear ask, not budget | Flowjam [3P] | Medium |

### 5.2 What to borrow from the examples you named

I could source only some of these; the rest are labelled so you can verify by watching.

| Reference | What is documented | What to borrow |
|---|---|---|
| **Wispr Flow** | Notetaker launch staged a kid living a full adult day with the product narrating; India campaign found founders clearing a Slack backlog in autos outperformed other creative [3P adgully, X thread] | Deadpan absurdity around a boring category; real humans in real contexts. For Farside: someone approving an agent from an implausibly relaxed place |
| **Screen Studio-made videos** | Auto-zoom on click, cursor smoothing, motion blur, iPhone recording over USB with device frames [3P] | Farside's own feature is a follow-cam that tracks the pointer. Film that feature and let the edit mimic it |
| **Apple product films** | Macro detail, restrained typography, contrast in scale, pacing (fast then slow) and silence against heavy beats [3P] | One typeface, few words per card, silence before the click sound |
| **Raycast, Arc, Granola** | I found no sourced breakdown of their launch videos [3P search] | Unverified. Watch each once with sound and note: seconds to first payoff, number of cuts per 10 s, whether UI is ever generated |

### 5.3 Formats that fit Farside [INFER, supported by 5.1]

1. **Problem-first POV**: "Your agent has been waiting 41 minutes."
2. **Split-screen cause and effect**: thumb on phone left, Mac pointer moving right. This is the proof shot and it cannot be faked by AI.
3. **Tactile ASMR**: haptic click plus foley, close and dry.
4. **"Places I approved my agent from" listicle** (45 s cut).
5. **Deadpan status-message humour**, using the app's own copy ("Your Mac is napping").

### 5.4 Hook lines (verify each claim against the shipped build)

1. "Your agent has been waiting 41 minutes."
2. "Your Mac is over there. You're not."
3. "Approve the agent from the couch."
4. "The whole screen is a trackpad."
5. "Feel the click."
6. "Talk to your phone. It types on your Mac."
7. "Please don't walk back to your desk."
8. "Your Mac just asked permission. Again."

---

## 6. Production plan

### 6.1 Asset library

Real (R), generated (G), motion graphics and procedural (M). **Capture the R-screen assets last, from the release-candidate build**: the UI is still moving under the native-experience work and the dither redesign [REPO], and any UI change invalidates footage.

| ID | Type | Asset | Who / how |
|---|---|---|---|
| R1 | Real | iPhone screen recording of a live session (home, connect, drag, click, pinch-zoom, dictation, clipboard) | Owner. Built-in iPhone screen recording (Control Center) or QuickTime over USB (File, New Movie Recording, pick the iPhone) |
| R2 | Real | Mac screen recording of the same session (pointer moving because the phone moves it) | Owner. Cmd-Shift-5 or Screen Studio [3P]. Record R1 and R2 simultaneously on independent devices; sync with a clap |
| R3 | Real | Lock-screen push "Your agent needs you" plus tap-through | Owner, only if the beta push works on the RC build |
| R4 | Real | Owner's hand reaching on black | Owner, section 6.8 |
| R5 | Real | Thumb-on-glass macro; phone buzzing on a nightstand; Mac glowing in the dark | Owner (each takes minutes; shoot rather than generate) |
| G1 | Gen | Void with fingertip and ember point (fallback to R4) | Higgsfield |
| G2 | Gen | Back of an open laptop in a dark room, screen glow spilling round the lid | Higgsfield (fallback R5) |
| G3 | Gen | Phone face-down on a nightstand, buzz and light leak | Higgsfield (fallback R5) |
| G4 | Gen | Night-train window, rain, blurred city lights | Higgsfield (real is harder) |
| G5 | Gen | Overgrown doorway (hero alternative) | Higgsfield |
| M1 | Motion | Signal-lock transition: noise threshold resolves into the real desktop | ffmpeg, Resolve/After Effects, or the site's canvas shader |
| M2 | Motion | Pixel-arrow cursor and halftone ripple on touch | Motion graphics or the site's canvas |
| M3 | Motion | End card with the hybrid wordmark | Design file |

### 6.2 Website hero loop: concepts (6 to 12 s, full-bleed, dark, behind text)

**Ranking for video** [INFER]: H1 and H2 first (real material, zero or near-zero credits), H3 for the cinematic Higgsfield showpiece, H4 only if it wins as a concept.

| ID | Concept (from DITHER-BRIEF) | Build | Credits | Risk |
|---|---|---|---|---|
| **H1** | **Transmission** (`23-transmission`): scanlines and noise resolve into your real desktop, phosphor or ember, "TRANSMISSION RECEIVED" | Real Mac screen recording, procedural noise-to-image threshold sweep (M1), CRT scanlines, loop: noise, desktop, noise | 0 | Low. UI is real; at hero scale legibility does not matter |
| **H2** | **Reach** (`21-reach`): fingertip and pixel cursor across a void | Owner's real hand on black (R4), halftone pass, procedural cursor (M2). Loop: hand approaches, hovers 8 cm short, eases back (a breath). Optional machine hand: generate a stylized hand still and drive it with `hf_mult_motion_control` from R4 | 0, or about 30 to 150 for the machine hand | Low with real hand; medium with generated hand |
| **H3** | **Overgrown** (`25-overgrown`): stippled painterly meadow, a glowing doorway (the Mac window) in the wilderness | Fully generated, environment only. Section 6.4 (G5) | 130 to 320 | Low (no hands, faces or text) |
| H4 | Afterglow (`27-afterglow`): person on a night train lit by their phone | Generated. Face plus phone glow is the hardest thing on the list; only viable as a back-of-head silhouette with the glow on the window | 200 to 400 (my estimate) | High |

**Making it work behind text** [INFER]: keep luminance low and flat through the headline band; place bright elements at the edges; use a coarse dot pitch (3 px cells at 1080p or coarser) with only 4 to 6 tone levels; add a radial vignette scrim; test with the real headline at 390 px and 1440 px wide, in both bright and dim viewing conditions.

**Loop method** (avoid identical start and end frames; models often produce almost no motion) [3P]: (1) generate clip 1 from still A; (2) generate clip 2 with start frame = last frame of clip 1 and end frame = first frame of clip 1; (3) trim one frame from each clip and concatenate. Two 5 s halves give a 10 s loop with an exact seam. Alternatives: crossfade the tail into the head. I tested the crossfade filter graph: a 10 s source gives a 9 s loop whose seam scores 32.8 dB PSNR against 34.5 dB between ordinary adjacent frames and 12.4 dB for a naive wrap (Appendix A) [MEAS, synthetic source]. **Higgsfield models that accept both `start_image` and `end_image`:** `seedance_2_0/2_5`, `kling3_0`, `cinematic_studio_3_0`, `minimax_h3(_max)`, `flux_3_video`, `veo3_1_lite`, `gemini_omni_flash_1_1`, `wan3_0`. (`veo3_1` full takes a start frame only.)

**Web delivery** [3P best practices, HEUR]: muted, `autoplay loop playsinline`, `preload="metadata"`, a poster frame identical to frame 1; 24 to 30 fps; H.264 MP4 as the safe baseline, AV1 or WebM optional (reported 30 to 50 percent smaller); serve a poster or a smaller file on narrow screens; honour `prefers-reduced-motion` by not playing (the brief already requires a still frame). Ordered dither at 3 px cells encoded at 2.8 MB per 10 s in my test; error diffusion and temporal grain are not web-friendly (section 6.7).

```html
<video class="hero-video" autoplay muted loop playsinline preload="metadata"
       poster="hero-poster.jpg" aria-hidden="true">
  <source src="hero-1080.h264.mp4" type="video/mp4">
</video>
<script>
  const v = document.querySelector('.hero-video');
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) v.remove();
</script>
```

Keep the canvas hero from the concept files as the reduced-motion and slow-network fallback, per the brief ("design so a video could replace the canvas").

### 6.3 Social videos: shot lists

Conventions: `REAL` = captured on iPhone or Mac; `GEN` = Higgsfield plate (dithered); `MOTION` = motion graphics. Type: Doto for hook plates, Geist Mono for captions, bone or white text on black, ember on one keyword. Every cut is captioned (assume sound off first). Keep faces, captions and the CTA out of the top 120 px, the right-hand action column and the bottom 250 px [3P safe zones].

#### V15 "Blocked" (9:16, 15 s): the agent-alert hook

| # | t (s) | Source | Picture | Sound | Text |
|---|---|---|---|---|---|
| 1 | 0.0 to 1.4 | REAL Mac (crisp) | A terminal: the agent has stopped at a permission prompt; cursor blinks; clock reads 02:14 | Chime, then silence | "YOUR AGENT HAS BEEN WAITING 41 MIN." (typed on in 0.4 s) |
| 2 | 1.4 to 3.0 | GEN G3 or REAL R5 | Phone face-down on a nightstand buzzes; light leaks round its edge | Buzz, room tone | none |
| 3 | 3.0 to 4.6 | REAL R3 | Lock screen: "Your agent needs you" | Notification chime | none |
| 4 | 4.6 to 9.0 | REAL R1 + R2, split (phone 40% left, Mac right) | Tap notification, Farside opens on the Mac's screen, thumb drags, pointer glides to Allow, click | Foley click synced to each click, beat starts | "TAP." then "THAT'S IT." |
| 5 | 9.0 to 11.0 | REAL Mac | Agent resumes, output streams | Ticks accelerate | none |
| 6 | 11.0 to 13.0 | GEN G2 (dither, ember) | Slow push-in on the glowing back of the laptop in a dark room | Low hum | "YOUR MAC IS OVER THERE. YOU'RE NOT." |
| 7 | 13.0 to 15.0 | MOTION M3 | Wordmark and line | Single tone | "Farside. See and control your Mac from your iPhone." Small: "Free on your Wi-Fi. Remote is a paid add-on." plus CTA per D3 |

Generated share: G3 plus G2 = about 3.6 s of 15 (24%).

#### V30 "Reach" (9:16, 30 s): the brand film with the demo

| # | t (s) | Source | Picture | Sound | Text |
|---|---|---|---|---|---|
| 1 | 0.0 to 2.4 | REAL R4 halftone (or GEN G1) | A fingertip drifts toward a small ember point in the void | Low drone swell | "YOUR MAC. OVER THERE." |
| 2 | 2.4 to 4.6 | REAL R5 macro + MOTION M2 | Thumb touches glass; the halftone ripples out | Tick | none |
| 3 | 4.6 to 10.0 | REAL R1 + R2 split | Drag anywhere; the Mac pointer follows one to one; click and haptic | Foley clicks in rhythm | "THE WHOLE SCREEN IS A TRACKPAD." |
| 4 | 10.0 to 15.0 | REAL R1 | Pinch to zoom on a tiny toolbar button; the view follows the pointer; click | | "IT FOLLOWS YOUR POINTER." |
| 5 | 15.0 to 20.5 | REAL R1 + R2 | Owner speaks into the phone; words fill a Mac text field | Dry voice | "SAY IT. IT TYPES." |
| 6 | 20.5 to 24.0 | REAL R1 | Clipboard: copy on the Mac, paste on the phone | Two ticks | "COPY HERE. PASTE THERE." |
| 7 | 24.0 to 27.0 | GEN G4 (dither) with small REAL overlay | Rain on a train window; phone overlay if Remote is live (D4) | Rain, rumble | "ANYWHERE.*" footnote "*Farside Remote, a subscription." (omit shot if Remote is not live) |
| 8 | 27.0 to 30.0 | MOTION M3 | End card | Tone | as V15 |

Generated share: G1 (or R4) 2.4 s plus G4 3 s = 5.4 s of 30 (18%).

#### V45 "Three places" (9:16, 45 s; also the YouTube and X master)

| # | t (s) | Source | Picture | Text |
|---|---|---|---|---|
| 1 | 0.0 to 3.0 | REAL Mac | Agent stopped at a prompt | "THREE PLACES YOU'RE NOT AT YOUR MAC." |
| 2 | 3.0 to 14.0 | REAL R5 + R1 | Kitchen: coffee, phone propped; approve the agent (owner, real) | "1. THE KITCHEN." |
| 3 | 14.0 to 25.0 | REAL R5 + R1 | Couch: dictate a reply into the Mac | "2. THE COUCH." |
| 4 | 25.0 to 36.0 | GEN G4 + REAL R1 | Transit: rain window, then the phone; pointer moves the Mac (if Remote is live; else use a second Wi-Fi place such as the garden) | "3. SOMEWHERE ELSE.*" |
| 5 | 36.0 to 41.0 | REAL montage on the beat | Five 1-s cuts of the four core actions, each with a click foley | none |
| 6 | 41.0 to 45.0 | MOTION M3 | End card | as V15 |

Pattern interrupts land every 3 to 5 s (cut, punch-in, text change, sound hit, split screen); open loops at 10 to 15 s ("wait for number 3").

#### Cutdowns

- **1:1 (1080x1080):** centre-crop the 9:16 master; re-place captions, which sit below the crop.
- **16:9 (1920x1080):** rebuild, do not crop: phone recording at full height on the left, Mac recording on the right, a dithered blow-up of the Mac recording as the background. Needs 16:9 versions of G1, G2 and G4 (3 extra generations, counted in section 6.5).
- **Apple App Preview (separate deliverable):** pure R1 footage with no Higgsfield, no dither, no hands, no device frames, 15 to 30 s (section 6.7).

### 6.4 Generated-shot spec sheets (exact model, settings, prompts)

All shots: `generate_audio: false` (we add our own sound; sound-off is also documented to lower Kling credits), drafts first, `get_cost: true` before each submit, `folder_id` `1996effd-7ac7-41c1-af5b-2e7ad8d67886`. Stills first (`nano_banana_pro`, `resolution: "2k"`, `count: 3`, about 6 credits per shot), then `seedance_2_5` drafts (`draft: true`, 480p), then finals. Paste the Farside global style block (4.3) at the top of each video prompt. The video prompts use the documented Seedance section format.

**G1: Void, fingertip and ember point** (hero H2 alternative and V30 opener). 16:9 for the hero, 9:16 for V30.

- Still prompt: "A single adult human right hand enters from the lower-left edge in an endless black void, index finger extended and relaxed, side profile. A tiny pinpoint of ember-orange light floats at centre-right. Extremely low-key, single narrow rim light from upper right, matte skin with visible pores, unretouched, 50mm, shallow focus on the fingertip, 35mm film grain. Exactly one hand with five fingers. No text, no logos, no other objects."
- Video (`seedance_2_5`, 5 s draft at 480p, then 1080p): SCENE: the hand drifts about 20% of the frame width toward the light, stops about 8 cm short, holds with a faint living tremor. FIRST FRAME: hand at lower left, wrist cropped by the frame, fingertip pointing right. CAMERA: locked-off with a 1% push-in over 5 s. OPTICS: 50mm, T2.8. PHYSICS: skin and tendons move naturally, no morphing; dust motes drift through the beam. LIGHTING: one rim light, ember on the fingertip edge, no fill. AUDIO: none. Exclusions: "exactly one hand, five fingers, no duplicate hands, no text, no logos".
- Loop: two-half method. Credits: about 6 + 15 + 60 to 120 = 80 to 140. **Fallback and my preference: R4 real hand.**

**G2: The back of the laptop** (V15 shot 6, V45). 9:16 and 16:9.

- Still prompt: "A dim home office at night seen from behind and slightly to the left of an empty chair. An open silver laptop stands on the desk, viewed from behind: the back of the lid is plain matte aluminium with no logo, and pale green-white light from the unseen screen spills around the lid edges onto the desk and wall. The rest of the room is near black with faint cold street light through a window. Dust hangs in the glow. No people. Nothing readable anywhere."
- Video (`seedance_2_5`, 4 s): "Locked-off frame, barely perceptible 1% push-in. Dust drifts through the glow; the light breathes very slightly as if the screen content changes. No lens drift. No logos, no readable text, no rendered content on any screen. AUDIO: none."
- Credits: about 6 + 12 (draft) + 27 (720p final) = 45.

**G3: Phone face-down on a nightstand** (V15 shot 2). 9:16.

- Still prompt: "Close, low-angle 35mm view of a smartphone lying face-down on a dark wood nightstand at night, plain matte back, no logo, no text, no hands. A glass of water is blurred behind it. Faint cold light leaks round the phone's edges onto the wood."
- Video (`seedance_2_5`, 4 s): "Locked-off. The phone buzzes for 1.5 s: it shivers on the wood, ripples cross the water, and light flares round its edges and glows on the ceiling, then settles. No hands, no logos, no readable text, no visible screen."
- Credits: about 6 + 12 + 27 = 45. Fallback: shoot it (2 minutes).

**G4: Night-train window** (V30 shot 7, V45). 9:16 and 16:9.

- Still prompt: "Interior of a night train carriage: a rain-streaked window with blurred city lights, cold cyan and sodium-ember bokeh, faint reflection of a dim cabin light in the glass, shallow depth of field. No people, no signs, no text."
- Video (`seedance_2_5`, 5 s, or `kling3_0` with `sound: "off"` for about half the price): "Handheld with very subtle operator breathing, real human correction, no drone glide. Lights slide past; raindrops run down the glass at different speeds. No people, no text."
- Credits: about 6 + 15 + 33 = 55 (Kling finals about 25).

**G5: Overgrown doorway** (hero H3). 16:9, 21:9 optional.

- Still prompt: "A wild overgrown meadow at blue dusk. In the distance a single tall rectangular doorway of pale gold-green light stands in the tall grass like a lit window frame. Backlit flowering weeds, haze, pollen in the light beam. Painterly-real, 35mm, gentle halation, grain. No people, no buildings, no signs, no text."
- Video (`seedance_2_5` or `kling3_0` `mode: "pro"`, two 5 s halves): "Very slow forward drift of about 1 m over the clip, operator-steady. Grass sways in gusts; pollen drifts through the beam; the doorway glow breathes very slightly. No shake. No people, no text, no logos."
- Loop: two-half method. Credits: about 20 (10 stills) + 4 drafts (60) + finals (Kling pro 1080p, 2 halves x 2 takes x 12.5 = 50; or Seedance 1080p at 12 per second, 2 halves x 2 takes x 60 = 240). Range 130 to 320.

QA for every finished plate (all must pass): no fingers or extra limbs; no legible text or logo anywhere in frame; no screen content; no morphing or lens drift; loop seam invisible at full speed; the plate still reads after the dither pass at phone size, at arm's length, sound off.

### 6.5 Credit budget

**Assumptions.** Per generated 4 to 5 s shot: 3 stills (6 credits) plus, on the Seedance path, one 480p draft (about 12 to 15) and one 720p final (about 27 to 33), times 1.5 for average retakes, which is about 71 per shot; on the Kling path, two 1080p takes at about 12.5 each plus stills, about 31 per shot. Rates used (credits per second): Seedance 2.5 draft 3, 720p 6.6, 1080p 12; Kling 3.0 about 2 to 2.5; images 2 each. **Every line is plus or minus 30 percent until `get_cost` confirms it.** $0.05 per credit.

| Line | Lean path (real-first hero, Kling finals) | Full path (generated hero, Seedance finals) |
|---|---|---|
| **Stage-0 test** (6.6) | 30 | 45 |
| Website hero loop | 0 (H1 or H2, real material) | 260 (range 130 to 320; H3 generated) |
| 9:16 B-roll library | 93 (G2, G3, G4) | 284 (G1, G2, G3, G4) |
| 16:9 variants for the 16:9 cutdown | 62 (G2, G4) | 213 (G1, G2, G4) |
| Extra stills and de-slop passes (about 15) | 30 | 50 |
| Voice-over | 0 (owner records; Higgsfield TTS as fallback) | 0 |
| **Subtotal** | **about 215** | **about 850** |
| Contingency 30% (re-rolls are charged) | +65 | +255 |
| **Total** | **about 280 (about $14)** | **about 1,100 (about $55)** |

**Per deliverable** (a shot is generated once and reused, so a later video costs almost nothing extra):

| Deliverable | Generated shots it needs | Lean | Full |
|---|---|---|---|
| Website hero | none (H1/H2) or G5 (H3) | 0 | about 260 |
| V15 "Blocked" (9:16) | G3, G2 | about 62 | about 142 |
| V30 "Reach" (9:16) | G1 or real R4, plus G4 | about 31 (R4 real) | about 142 |
| V45 "Three places" (9:16) | G4, G2 (reused) | 0 extra | 0 extra |
| 1:1 cutdowns | none (crop) | 0 | 0 |
| 16:9 cutdowns | 16:9 versions of G2, G4 (and G1) | about 62 | about 213 |
| App Preview | none (pure app footage) | 0 | 0 |

The real cost per video is the owner's shooting time, not credits. Available: 636 now plus 1,000 after the reset on about 6 Oct (2.4). Suggested staging: Stage 0 now; Stage 1 (generative hero if chosen, plus the 9:16 B-roll library) before the reset so the credits would otherwise lapse; Stage 2 (16:9 variants, retakes) after. Full path would not fit before the reset; it fits across the two balances.

### 6.6 Cheapest path to a first test (for approval before spending more)

**Zero-credit first (30 minutes):** T0. Record 10 s of any real Mac screen session and one real hand reaching on black. Run the tested dither chain (Appendix A) on the hand and a bordered version on the screen. This answers "what does the brand look like on real material" with no spend and may pick the hero for you.

**Then T1, about 21 to 45 credits:**
1. Three stills of G1 with `nano_banana_pro`, 16:9, `resolution: "2k"`, `count: 3` (about 6 credits).
2. One `seedance_2_5` **draft**: `draft: true`, 480p, 5 s, `generate_audio: false`, start image = the best still (about 15 credits at 3 per second; the documented 8 s figure is 24). Optional second option: `seedance_2_0_mini` (a 10-credit job in the history [OBS]), different model so the look may differ.
3. Run the dither and ember chain on the draft (0 credits).
4. Assemble `look-test.mp4`, 15 s vertical: hand draft with dither (0 to 5 s), real UI crisp inside a dithered border (5 to 10 s), split screen (10 to 15 s).

**Pass criteria:** no visible finger artifacts at dither scale; ember palette reads as the brand; headline overlay stays legible at 390 px and 1440 px; loop seam hidden at full speed. **If it passes:** finalize that draft at 1080p via `draft_job_id` (about 60 more credits) and proceed to Stage 1. **If the hand fails:** use R4 (real hand). The test costs at most about 45 credits (about $2) and leaves 590 or more.

### 6.7 Finishing pipeline

Order of operations:

1. **Ingest and name.** Folders: `01_real_screen`, `02_real_film`, `03_gen`, `04_audio`, `05_edit`, `06_exports`. Prefix files with the take number.
2. **Rough cut on real footage and voice**, script first. Add the G-shots as inserts of 4 s or less.
3. **Dither pass** on G-shots, transitions and hero (Appendix A); never on screen recordings.
4. **Unify:** one grade, a light grain over the whole cut (skip added temporal grain for the web hero), and a subtle vignette.
5. **Sound design** (4.5), then a loudness check.
6. **Captions:** burn in; hook plates in Doto, captions in Geist Mono; respect safe zones.
7. **Export** the masters below; QC on a phone at arm's length with sound off.

**Measured encode costs** [MEAS: 10 s, 1080p24, slow-moving gradient source; real footage will differ, so re-measure]:

| Treatment | File size | Reading |
|---|---|---|
| Source, x264 CRF 12 | 2.3 MB | baseline |
| **Bayer ordered dither**, 3 px cells (render at 1/3 size, nearest-neighbour upscale), CRF 18 | **2.8 MB** | static pattern, cheap, temporally stable |
| Floyd-Steinberg error diffusion, same setup | 21 MB (7.5 times) | pattern changes every frame; shimmer; do not use for video |
| Halftone dot screen at full resolution (`geq`, 1 px edges), CRF 18 | 45 MB | hard high-frequency edges; do not use at full res |
| Halftone at half resolution, nearest-neighbour upscale, CRF 22 | 6.0 MB | acceptable; about 18 px pitch at 1080p |
| Bayer plus ember map plus temporal grain (`noise=alls=6:allf=t`), `-tune grain`, CRF 20 | 17 MB (7 times the un-grained ember clip at 2.4 MB) | grain is what costs; fine for social, avoid on the web hero |

Tested chain look (still frames checked visually): a 6-level Bayer at scale 2 with a 3x nearest-neighbour upscale and the ember map looks cinematic and on-brand; a 4-level mono at scale 3 is too harsh and flat.

**Export specs**

| Target | Ratio, size | Frame rate | Codec, rate | Length | Notes |
|---|---|---|---|---|---|
| TikTok, Reels, Shorts | 9:16, 1080x1920 | 30 (60 for fast motion) [3P] | H.264 MP4, AAC, 8 to 12 Mbps [3P] | Shorts up to 3 min [3P] | Safe zones: top 120 px, bottom 250 px, right action column [3P] |
| Instagram feed / X / LinkedIn | 1:1, 1080x1080 (4:5 1080x1350 optional) | 30 | same | 15 to 45 s | Re-place captions |
| YouTube, website embed | 16:9, 1920x1080 | 24 or 30 | same | 30 to 90 s | Rebuilt layout, not a crop |
| **Website hero** | 16:9, 1920x1080 (720p for narrow screens) | 24 | H.264 MP4 (optional AV1 WebM), aim under 3 to 4 MB, no audio | 6 to 12 s loop | Poster frame plus reduced-motion fallback |
| **App Store App Preview (iPhone)** | **886x1920 portrait** [APPLE] | **30 max** [APPLE] | **H.264 10 to 12 Mbps VBR, up to High Profile L4.0; AAC 256 kbps stereo, 44.1/48 kHz** [APPLE] | **15 to 30 s, up to 3 per device, 500 MB max** [APPLE] | In-app footage only: **no device frames or hands** (my reading of Apple's spec page; re-check the wording before submitting). Simulator recordings lack audio and the right fps [3P SwiftLee] |
| iPad Preview | 1200x1600 portrait [APPLE] | 30 | same | same | Only if real iPad UI is shown |

Also: no prices in screenshots or previews (Guideline 2.3.7) and mark the subscription add-on clearly [REPO].

**Tools.** ffmpeg 9.0.2 is installed at `/opt/homebrew/bin/ffmpeg` on this Mac. `paletteuse` exposes `dither=bayer|heckbert|floyd_steinberg|sierra2|sierra2_4a|atkinson|none`, `bayer_scale` 1 to 5, and requires a 256-pixel palette image [MEAS, FFmpeg docs]. Halftone in DaVinci Resolve is done with Fusion macros, DCTLs or plug-ins, not a stock one-click effect (community tutorials, not verified) [3P]. Screen Studio records an iPhone over USB with device frames, auto-zoom and cursor smoothing [3P]. QuickTime gives full-resolution iPhone capture with no on-screen indicator [3P]. On a real device, touches are not shown natively; add a small debug-only touch-dot overlay to the app (engineering) if you want visible taps; the Simulator's own indicator is not captured by `simctl` recordings [3P Maestro].

### 6.8 What the owner films and captures

1. **Demo Mac account.** A clean macOS user with a dark wallpaper, no personal data, notifications off (Do Not Disturb), a tidy Dock, a generic terminal with a generic agent prompt (no vendor logos).
2. **Screens (last, from the RC build):** portrait iPhone recordings of home and connect, live drag and click, pinch-zoom follow, dictation, clipboard, the agent push (if real), the friendly error ("Your Mac is napping"). Native resolution; export at 30 fps. Simultaneous Mac recording of the same session for the split screen; clap to sync.
3. **Hand on black (R4):** dark room, black cloth, one warm side lamp as rim light, matte skin (powder to cut sheen), phone locked on a tripod at 4K, exposure and focus locked. Twenty short reaches, slow, ending 8 cm short of nothing.
4. **Thumb on glass (R5):** over-the-shoulder or macro. Film the phone's real screen at 1/60 s shutter and 30 fps to reduce banding [HEUR], or shoot with the screen black and corner-pin the recording in post.
5. **Ambience shots (each minutes long to shoot):** phone buzzing on the nightstand; Mac glowing in a dark room (tape over the lid's Apple logo); a rain window if you take a train.
6. **Sound:** a 30 s room tone per location; finger taps on glass; one mechanical switch click; a nightstand buzz; voice-over recorded in a clothes-filled closet with the phone.
7. **Consistency:** shoot everything vertical; three seconds of pre- and post-roll; clap for sync; no third-party logos or agent brand UIs in frame.
8. **Releases and rights:** only you on camera (no releases needed); no third-party music unless licensed for the platform.

### 6.9 Schedule (back-planned from the proposed 17 Nov)

| When | What |
|---|---|
| By 5 Oct | Decisions D1 to D3; T0 and T1 test; approve or reject the look; concept chosen (D2) |
| Before about 6 Oct (credits reset) | Stage 1 generation if the test passed: hero if generative plus the B-roll library |
| 6 to 19 Oct | Owner shoot day (R4, R5, sound); build M1 to M3; hero loop delivered to the site |
| 20 to 26 Oct | Edit V15, V30, V45 and the 1:1 and 16:9 cutdowns with the real hero and B-roll |
| By about 26 Oct | Capture R1 to R3 from the RC build; swap into the cuts; App Preview capture |
| 27 Oct to 1 Nov | QC, label toggles, claim check against the store listing |
| 2 Nov | Go/no-go; only then fix the date on creatives |
| 3 to 16 Nov | Teasers (V15 first) if the date is committed |
| 17 Nov | Hero live; V30 on all vertical platforms; V45 on YouTube and X |

---

## 7. Cost-of-mistake notes

- Re-rolls and upscales are charged [3P Krea]; finalize a draft only after the take is picked.
- Parallel limits on Plus: 6 videos and 8 images at once [HF-MCP]; batch drafts, not finals.
- Do not upload anything private as a reference (the demo account exists for this reason).
- Seedance region note: one third-party page says Seedance is unavailable in the US on the provider side [3P Picsart]; this account (Canada) generated a Seedance 2.5 job on 7 Sep [OBS], so it works here. Recheck if a US-based collaborator runs it.

## 8. Claims and legal guardrails

- **Match the store listing's own checklist** [REPO]: remote "from anywhere" was not deployed on 28 Sep; the 30-minute room cap contradicts "no time limit"; iPad is a basic adaptive layout; voice dictation is unverified per language; "scan a code and approve" is not yet acceptance-tested. Do not show or say what the RC build does not do.
- **Trademark:** never write "Far Side" or "The Far Side"; no cow or comic imagery; use "Farside" as one word [REPO].
- **Advertising and Apple rules:** no prices in previews (2.3.7); subscription add-on clearly marked; only shipped features.
- **AI disclosure** (4.6) and **music licensing** (4.5).
- **Third-party marks:** no Apple logo on laptops or phones, no agent-vendor logos or UIs.
- **Privacy:** screen recordings can leak notifications and files; demo account only.

## 9. Sources (retrieved 28 Sep 2026 unless noted)

Higgsfield MCP (live tool output): `balance`, `list_workspaces`, `transactions`, `show_plans_and_credits`, `models_explore` (list, get, recommend, search), `get_workflow_instructions` (catalog; `ugc-website-video`, `character-sheet`, `video-editing`, `ad-multiplier`), `get_workflow_bundle_file` (ugc-website-video references), `get_preset_instructions`, `get_presets` (marketing_studio, motion), `shorts_studio_list_presets`, `list_voices`, `show_characters`, `show_reference_elements`, `list_projects`, and the tool schemas for `generate_video`, `generate_image`, `generate_audio`.

Higgsfield web:
- Seedance 2.5 pricing, 6 Aug 2026: https://higgsfield.ai/blog/seedance-2-5-pricing-2026
- Seedance 2.5 on Higgsfield, 6 Aug (modified 19 Sep): https://higgsfield.ai/blog/seedance-2-5-on-higgsfield-2026
- Seedance 2.5 prompting guide (undated): https://higgsfield.ai/blog/seedance-2-5-prompting-guide
- Credits vs unlimited, 11 Sep: https://higgsfield.ai/blog/credits-vs-unlimited-ai-video-generation
- Five best video models, 9 Jun (updated 29 Aug): https://higgsfield.ai/blog/5-Best-AI-Video-Models-2026-Tested-Compared
- Cinema Studio 3.0, 30 Mar (modified 21 Sep): https://higgsfield.ai/blog/cinema-studio-3
- Cinema Studio 4.0, 12 Aug: https://higgsfield.ai/blog/cinema-studio-4-0
- Higgsfield MCP overview, 29 Aug: https://higgsfield.ai/blog/Generate-AI-Videos-From-Claude-with-Higgsfield-MCP
- Changelog: https://higgsfield.ai/creator-hub/changelog

Third party:
- Krea, Higgsfield pricing (data verified 31 Aug): https://www.krea.ai/blog/higgsfield-pricing-explained-2026-unlimited-credits-and-real-monthly-costs
- TechSifted, Higgsfield pricing (5 to 28 Sep): https://techsifted.com/roundups/higgsfield-ai-pricing-2026/
- Picsart, Seedance 2.5 draft mode: https://picsart.com/blog/seedance-2-5-draft-mode-explained/
- Google Cloud, Veo 3.1 prompting guide, 15 Oct 2025: https://cloud.google.com/blog/products/ai-machine-learning/ultimate-prompting-guide-for-veo-3-1
- Realism tips: https://www.pixelbin.io/blog/how-to-make-realistic-ai-videos , https://invideo.io/blog/ai-video-post-production/ , https://sunra.ai/blog/make-ai-video-look-less-ai , https://lumalabs.ai/news/prompt-realistic-ai-videos
- Model comparisons: https://www.buildfastwithai.com/blogs/seedance-2-5-vs-veo-3-1-vs-kling-3-0-best-ai-video-2026 , https://www.krea.ai/blog/seedance-2-5-vs-veo-3-1-which-is-better-full-comparison-2026 , https://the-decoder.com/black-forest-labs-makes-flux-3-video-generally-available-and-claims-it-beats-seedance-2-0/ , https://www.therundown.ai/tools/gemini-omni-1-1-flash , https://www.minimax.io/blog/minimax-h3
- Loop technique: https://ffmpeg.party/guides/ai-video-loop/
- Dithering: https://en.wikipedia.org/wiki/Ordered_dithering , https://www.turbodither.com/learn/ordered-dithering-vs-error-diffusion
- FFmpeg filters: https://ffmpeg.org/ffmpeg-filters.html#paletteuse
- Hero video practices: https://www.hostarmada.com/blog/video-hero-section/ , https://web.dev/learn/accessibility/motion
- Hooks and retention: https://www.teleprompter.com/blog/tiktok-3-second-rule , https://edicionvideopro.com/en/editing-for-platforms-video-marketing/pattern-interrupts-tiktok-retention-guide/
- Launch video guidance: https://www.flowjam.com/blog/30-best-launch-video-examples-checklist , https://ugcscout.com/blog/startup-launch-video-benchmarks-x
- Wispr Flow: https://www.adgully.com/post/15661/wispr-flows-india-launch-driven-through-multi-platform-campaign-by-owled-media
- Apple-style film craft: https://motion.so/learn/apple-style-product-launch-video
- Screen Studio and iPhone capture: https://screen.studio/guide/auto-zoom , https://tight.studio/blog/how-to-screen-record-iphone-on-mac/ , https://www.avanderlee.com/workflow/capture-ios-simulator-video-app-preview/ , https://maestro.dev/blog/showing-tap-indicators-on-ios-recordings
- Platform specs: https://www.clipspeed.ai/blog/video-resolution-guide-shorts-reels-tiktok.html , https://anfx.co/blog/youtube-shorts-tiktok-reels-video-size-guide/
- AI labelling: https://newsroom.tiktok.com/en-us/new-labels-for-disclosing-ai-generated-content , https://blog.youtube/news-and-events/disclosing-ai-generated-content/ , https://www.techwyse.com/news/platform-updates/youtube-automatic-ai-labels-disclosure-may-2026 , https://coinis.com/blog/meta-ai-content-labeling-facebook-instagram-ads-2026
- TikTok music licensing: https://www.soundstripe.com/blogs/tiktok-music-library-explained

Apple: App preview specifications, https://developer.apple.com/help/app-store-connect/reference/app-preview-specifications/ (retrieved 28 Sep 2026; the "in-app footage only, no device frames or hands" reading comes from a summarised fetch, so confirm the wording).

Repository: `PRODUCT.md` (D27 to D31; 17 Nov target conditional on 2 Nov go/no-go), `Docs/launch/STORE-LISTING.md` (claim checklist, trademark notes), `design/farside-round1/DITHER-BRIEF.md`.

---

## Appendix A: tested ffmpeg commands (ffmpeg 9.0.2, macOS)

All tested on a synthetic clip, outputs inspected. `paletteuse` needs a palette image of exactly **256 pixels**; build one whose 256 entries quantize to N grey levels so tones stay fixed across clips (a per-clip `palettegen` can drift and flicker).

```bash
# 1. Fixed N-level grey palette (N=6 recommended; 4 is too harsh)
N=6
ffmpeg -y -f lavfi -i "color=c=black:s=16x16:r=1" \
  -vf "format=gray,geq=lum='255*floor($N*(Y*16+X)/256)/($N-1)':cb=128:cr=128,format=rgb24" \
  -frames:v 1 pal6.png

# 2. Bayer dither at 1/3 size, nearest-neighbour up (crisp 3 px cells), Farside ember map
#    (black to ember: R=v, G=0.52v, B=0.18v). Set gg=0 and bb=0 explicitly; the defaults are 1.
ffmpeg -y -i in.mp4 -i pal6.png -lavfi \
 "[0:v]scale=640:360:flags=area,format=gray,format=rgb24[x];\
  [x][1:v]paletteuse=dither=bayer:bayer_scale=2,\
  scale=1920:1080:flags=neighbor,\
  colorchannelmixer=rr=1:rg=0:rb=0:gr=0.52:gg=0:gb=0:br=0.18:bg=0:bb=0,\
  format=yuv420p" \
 -c:v libx264 -preset slow -crf 18 -r 24 -movflags +faststart dither_ember.mp4
# Mono variant: drop the colorchannelmixer step.

# 3. Optional temporal grain for SOCIAL exports only (about 7x file size)
#    add before format=yuv420p:  noise=alls=6:allf=t   and encode with  -tune grain -crf 20

# 4. Halftone dot screen (45 degrees), computed at half size, ~18 px pitch at 1080p
ffmpeg -y -i in.mp4 -vf \
 "scale=960:540:flags=area,format=gray,\
  geq=lum='if(gt(lum(X,Y)/255,(cos(2*PI*(X+Y)/12.7)+cos(2*PI*(X-Y)/12.7))/4+0.5),255,0)':cb=128:cr=128,\
  scale=1920:1080:flags=neighbor,format=yuv420p" \
 -c:v libx264 -crf 22 halftone.mp4
# Pitch below about 6 px at the computed size aliases into moire; render time was ~2 min per 10 s at full size.

# 5. Seamless loop by crossfading tail into head (1 s overlap; D=10 s in, 9 s out).
#    Measured seam (last frame to first frame) PSNR 32.8 dB vs 34.5 dB between adjacent frames and 12.4 dB for a naive wrap.
ffmpeg -y -i in.mp4 -filter_complex \
 "[0:v]split=3[s1][s2][s3];\
  [s1]trim=start=9:end=10,setpts=PTS-STARTPTS[t];\
  [s2]trim=start=0:end=1,setpts=PTS-STARTPTS[h];\
  [t][h]xfade=transition=fade:duration=1:offset=0[x];\
  [s3]trim=start=1:end=9,setpts=PTS-STARTPTS[m];\
  [x][m]concat=n=2:v=1:a=0[out]" \
 -map "[out]" -c:v libx264 -crf 18 -pix_fmt yuv420p loop.mp4
# General form: D = clip length, F = overlap. tail=[D-F,D], head=[0,F], body=[F,D-F]; output length D-F.

# 6. Center crops from a 16:9 master
ffmpeg -y -i master.mp4 -vf "crop=608:1080:(iw-608)/2:0,scale=1080:1920:flags=neighbor" out_916.mp4   # low-res: only for stills or plates
ffmpeg -y -i master.mp4 -vf "crop=1080:1080:(iw-1080)/2:0" out_11.mp4
```

## Appendix B: call templates for the executor (do not run without approval)

All templates carry `get_cost: true`: run them first to read the credit price without submitting.

```json
{"params":{"model":"nano_banana_pro","prompt":"<G1 still prompt, section 6.4>","aspect_ratio":"16:9","resolution":"2k","count":3,"folder_id":"1996effd-7ac7-41c1-af5b-2e7ad8d67886","get_cost":true}}
```

```json
{"params":{"model":"seedance_2_5","prompt":"<Farside global style + G1 video prompt>","mode":"omni_reference","duration":5,"resolution":"480p","draft":true,"generate_audio":false,"aspect_ratio":"16:9","medias":[{"value":"<still job_id or media_id>","role":"start_image"}],"folder_id":"1996effd-7ac7-41c1-af5b-2e7ad8d67886","get_cost":true}}
```

Notes: the correct `mode` for a start-frame clip is not spelled out in the schema (`omni_reference` is what Higgsfield's own workflow uses with image references); if rejected the server returns `adjustments`. Finalizing a draft passes `draft_job_id` and `resolution: "1080p"` per the parameter descriptions; the exact shape is untested. Kling variant: `{"params":{"model":"kling3_0","mode":"pro","sound":"off","duration":5,"aspect_ratio":"9:16","medias":[{"value":"<id>","role":"start_image"}],"get_cost":true}}`. Motion transfer: `{"params":{"model":"hf_mult_motion_control","resolution":"720p","medias":[{"value":"<hand still id>","role":"image_references"},{"value":"<R4 video id>","role":"video_references"}],"get_cost":true}}`.

Account check at the end of the research (28 Sep 2026): balance **636**, plan Plus, unchanged from the start. Only read-only Higgsfield tools were called; no `generate_*`, preset execution, upload, upscale or publish tool was used.
