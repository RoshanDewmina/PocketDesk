# Farside — dither / dystopian round (brief)

28 Sep 2026. The owner has chosen a direction: **dithered, dystopian, cinematic**. This supersedes the remaining directions of round 1. Look at the four reference images before designing (open them with the Read tool):

- `design/refs/ref-qintara-halftone-hands.png` — halftone/dot-matrix hands reaching toward each other (a human hand and a machine hand), a glowing voxel object between them, black ground, thin nav pill, one small white CTA, mono subhead. **The two hands reaching is our story: your fingertip on the phone reaching your Mac's pointer across a distance.** Don't copy the image; reinterpret it.
- `design/refs/ref-perplexity-duotone-portrait.webp` — grainy duotone (orange ↔ violet) poster over a starfield, serif headline with one italic word, tiny mono captions in the corners.
- `design/refs/ref-perplexity-dithered-forest.webp` — painterly, heavily dithered/stippled scene with a luminous doorway, one small serif line, logo at the bottom. Cinematic, calm, a little uncanny.
- `design/refs/ref-flora-node-wordmark.webp` — black dot-grid canvas, a hybrid wordmark (one italic serif capital + pixel/bitmap letters), thin spline connectors linking tool tiles to the centre, tiny two-line corner labels ("Creative / Tools", "Slide / 03").

Two layout patterns the owner likes (from prompts they pasted; use as structure, not copy):
1. Full-viewport, no-scroll cinematic hero: full-bleed moving background, small brand mark + nav top-left, a thin "timezone / status" panel and a white "Sign Up" pill top-right, a big two-line headline bottom-left with a line-by-line masked reveal, a short subhead, a white CTA with a dark arrow box, and a small glass "Watch demo" card bottom-right. One-shot staggered entrance timeline (~0–1.1 s, `cubic-bezier(.16,1,.3,1)` / `(.22,1,.36,1)`).
2. Centred single-viewport hero over a moving background: white pill nav with a three-dot active indicator, overlapping avatar "trusted by" row, a **dot-matrix display headline** in solid white, a muted subhead, a glowing white pill CTA, and a 4-up stats footer whose numbers count up (e.g. `38 ms` median latency, `0` accounts needed, `2560 px` sharp, `60 fps`).

## Hard rules
- The product is Farside: see and control your own Mac from your iPhone/iPad, anywhere. Brand voice: quirky, funny, a little dystopian-deadpan ("Your Mac is on the far side. You're not."), always clear about what a button does.
- **Dither is the brand layer; the app still has to "just work".** Show how the dither language carries into the phone and Mac UI without hurting legibility (e.g. dithered backgrounds and illustrations, crisp UI text and controls on top).
- All moving backgrounds must be **procedural**: canvas/WebGL ordered (Bayer 4×4/8×8) or error-diffusion (Floyd–Steinberg/Atkinson) dithering, halftone dot screens, grain, scanlines — no external video or images (the artifact CSP blocks them). A later round may swap in a Higgsfield-generated hero video; design so a video could replace the canvas.
- Hands and figures: draw as simple SVG silhouettes, then rasterise and halftone/dither them in canvas. Keep them tasteful and original.
- Fonts from Google Fonts only. Good dot-matrix/pixel faces there: **Doto** (variable dot-matrix), Sixtyfour, Silkscreen, Pixelify Sans, DotGothic16, Handjet, VT323, Micro 5, Jersey 10. Serifs for the italic contrast word: Instrument Serif, Newsreader, Cormorant Garamond. Mono captions: Geist Mono, JetBrains Mono, IBM Plex Mono. No Inter, no Space Grotesk, no Playfair Display.
- Palettes: black or near-black grounds; white/bone dots; at most one duotone pair or one accent (e.g. ember orange, sodium-vapour amber, phosphor green, signal red, UV violet). No purple-to-blue gradient heroes.
- Respect `prefers-reduced-motion` (show a still dithered frame). Must work at 390 px wide with no horizontal body scroll.
- Same technical constraints as round 1: self-contained HTML, `<!doctype html>`, charset + viewport (`viewport-fit=cover`) metas, `<title>Farside — <Concept></title>`, scripts only from cdnjs (pinned), styles only from Google Fonts, explicit body background, under ~400 KB.

## What each concept file contains
1. A **full-viewport website hero** (pattern 1 or 2 above, or your own) with the animated dithered background and the entrance timeline.
2. Below it (scroll is fine inside the concept file): the brand kit strip (wordmark, app icon at 1024/180/60 px, palette, type), then **iPhone screens** in 390×844 frames: Home (Mac card + Connect), live session with the phone-drawn pointer and only a tiny dock handle, dock swiped up, first-run gesture tutorial (quirky practice task), friendly error ("Your Mac is napping"), plus the **Mac menu-bar popover** and **setup window** (permissions step).
3. One signature motion moment (e.g. the fingertip and pointer closing the gap and "connecting" with a ripple; the moon's far side lighting up; a transmission locking on).

## Concepts (one file each in `design/farside-round1/`)
- `21-reach.html` — **Reach.** Halftone hands across a black void: a human fingertip (phone side) and a pixel arrow cursor (Mac side). When they touch, the dots ripple and the headline appears. White dots + one ember accent. Dot-matrix headline (Doto).
- `22-far-side.html` — **The Far Side.** A Bayer-dithered moon in duotone (sodium amber ↔ UV violet) with grain; the dark side is lit by a tiny glowing laptop screen. Serif headline with one italic word, mono corner captions like the Perplexity poster.
- `23-transmission.html` — **Transmission.** Dystopian broadcast: CRT scanlines, signal noise resolving into your desktop, "TRANSMISSION FROM YOUR DESK — RECEIVED", phosphor green on black, terminal mono + one serif line.
- `24-constellation.html` — **Constellation.** Flora-like black dot-grid canvas and a hybrid wordmark (italic serif "F" + pixel "arside"); thin spline connectors from the phone at the centre to dithered tiles of Mac apps (Terminal, Xcode, Figma, a browser) — "Everything on your Mac, one thumb away."
- `25-overgrown.html` — **Overgrown.** Perplexity-forest energy: a stippled, painterly dithered landscape with a glowing Mac window as a doorway in the wilderness — "Work from the far side of anywhere." Calm, uncanny, green-gold.
- `26-monitored.html` — **Monitored.** Deadpan surveillance parody: halftone CCTV frames, redaction bars, timestamps, a blinking REC dot — the joke is that the only one watching your Mac is you. Signal red accent. Keep it funny, not creepy.
- `27-afterglow.html` — **Afterglow.** Grainy duotone portrait of a person on a night train lit by their phone, error-diffusion dithered, orange ↔ violet; serif "Your Mac, *never* far." Poster-like, very cinematic.
- `28-dither-os.html` — **Dither OS.** A design-system concept for the app itself: how dithered materials, 1-bit icons, dot-matrix numerals and crisp controls combine in the phone and Mac UI. Fewest website theatrics, most UI detail (components sheet: buttons, dock, status pills, keyboard toolbar, alerts, Live Activity / Dynamic Island compact and expanded states).
