# Farside website

Static marketing site for Farside, built to `design/FARSIDE-DESIGN-SYSTEM.md` and concept 21 · Reach. Dark only, no cookies, no analytics, no runtime dependencies. Deploys to Cloudflare Pages as plain files.

## Pages

| Path | What |
|---|---|
| `/` | Kept short (owner, 30 Sep 2026): hero with the "From the pocket" demo (`src/hero-pocket/`), a one-line promise and the beta form (`#beta`), three steps, four features, one pricing block, six questions with links to the guides |
| `/about` | Who makes Farside, what it is, where it stands, contact |
| `/control-mac-from-iphone` | Step-by-step guide (HowTo + FAQ structured data) |
| `/iphone-as-mac-trackpad` | Gestures, haptics, pointer, zoom (HowTo + FAQ) |
| `/remote-desktop-for-mac` | At home vs the Anywhere plan, how the connection works, limits (HowTo + FAQ) |
| `/compare` | Dated, sourced table vs Astropad Workbench, Jump Desktop, Screens 5, Remote Mac Desktop Control |
| `/support` | Setup, gestures, can't-connect checklist, every app message with its fix, billing, contact |
| `/privacy` | From `Docs/launch/PRIVACY-POLICY.md` §2; owner checklist in an HTML comment |
| `/terms` | Draft terms, clearly marked as not in effect; owner checklist in an HTML comment |
| `/404` | Served by Pages for unknown paths |

Also generated: `sitemap.xml`, `robots.txt`, `llms.txt`, `site.webmanifest`, `_headers`, `_redirects`, favicon set, one 1200×630 Open Graph card per main page.

The app association is copied to `dist/.well-known/apple-app-site-association` without an extension. The exact-path `_headers` rule serves it as `application/json`; there is no redirect. It names only the signed phone app and `/open`, `/open/*`, `/help/*`, and `/session`, matching `RemotePhone/SystemIntegrations/FarsideRoute.swift`. The build checks that its source matches `Docs/launch/apple-app-site-association` byte for byte and keeps this route list bounded. The chosen HTTPS domain still needs to serve and pass Apple's live association check before universal links can work on a phone.

## Commands (bun only)

```sh
bun install              # dev tools only: puppeteer-core, typescript, @types/bun
bun run build            # → dist/  (prints the placeholders still to fill)
bun run dev              # build + preview on http://localhost:4173, rebuilds on change
bun run serve            # preview dist/ as built
bun run check            # links, anchors, JSON-LD, no horizontal scroll 360–1440 px, console/CSP errors, copy rules
bun run lighthouse       # every page, mobile + desktop → reports/lighthouse/summary.md
bun run shots            # full-page screenshots → ~/Downloads/farside-site-<page>-<1440|390>.png
bun run assets -- --concept ../design/farside-round1/21-reach.html   # re-render OG cards, icons, art, design previews
bun run fonts            # re-measure the web fonts and regenerate src/styles/fallbacks.css
bun run typecheck
bun run build:strict     # refuses to build while required placeholders are empty; use for the real deploy
```

The preview server (`scripts/serve.ts`) behaves like Pages for this site: extensionless routes, `/page.html` → `/page`, `404.html` with a 404 status, `_headers`, `_redirects` and gzip.

## Build output: committed `dist/`

`dist/` is committed, so Cloudflare Pages serves it with **no build step** (and `wrangler pages deploy` needs nothing but the folder). JS and images in `dist/assets/` carry content hashes and a one-year immutable cache; pages and the CSS (inlined into each page) are revalidated. After changing anything in `src/`, `site.config.ts` or `static/`, run `bun run build` and commit `dist/` with the change. If you prefer Pages to build it, point the project at this folder with build command `bun install && bun run build:strict` and output `dist` (set `BUN_VERSION` in the Pages environment).

## The one URL placeholder: `SITE_URL`

Everything absolute (canonical links, Open Graph and Twitter images, JSON-LD, `sitemap.xml`, `robots.txt`, `llms.txt`) comes from `SITE_URL` in `site.config.ts`, currently the reserved placeholder `https://farside.example`. When the domain is bought, set it (https, no trailing slash) and rebuild; `SITE_URL=https://example.com bun run build` overrides it for one build. Nothing else hard-codes a domain.

## Deploy (after the domain is bought; nothing has been deployed)

```sh
bun run build:strict                                   # fails until site.config.ts is filled in
bunx wrangler login
bunx wrangler pages project create farside-site --production-branch main
bunx wrangler pages deploy dist --project-name farside-site --branch main
```

Custom domain: Pages → the project → Custom domains → add the apex and `www`; Cloudflare creates the DNS records when the zone is on Cloudflare. Redirect `www` to the apex with a Bulk Redirect (`_redirects` can't do host-level redirects). `_headers` already marks every `*.pages.dev` hostname `noindex`, and preview deployments get `noindex` from Pages by default. Before launch also: add the smart app banner (`launch.appStoreId`), swap the App Store placeholder for Apple's official badge artwork, and point `/download/mac/latest` at the notarized DMG (`launch.macDownloadUrl`).

## How it stays fast and safe

- **No render-blocking requests.** `src/styles/site.css` (≈27 KB) is inlined in every page and `src/styles/home.css` (≈26 KB: the hero demo and the home sections) only in the home page; the CSP allows both by SHA-256 hash (`scripts/build.ts` computes them). Scripts are deferred modules (home ≈ 52 KB including the hero demo and the footer field; other pages ≈ 12 KB).
- **Fonts** (Geist, Geist Mono, Doto, Instrument Serif from Google Fonts, `display=swap`, preconnected) load right after the first paint. Local fallback faces in `src/styles/fallbacks.css` are tuned to the web fonts' metrics, so the swap doesn't move the layout; the hero's accent word and full stop have pinned widths.
- **The hero demo** ("From the pocket", `src/hero-pocket/`, from the hero lab on `website/hero-lab`) sits in a box sized by CSS alone (the lab's tall 600 × 880 layout on phones, the wide 1000 × 640 one from 640 px), so it never moves the page. It starts once the web fonts have swapped in and the main thread is idle, draws with transforms on one clock that pauses off-screen and on hidden tabs, loops in about 18 s with a 0.3 s gap, and holds a still key frame for Reduce Motion, Save-Data or the pause button under it. Its MacBook is drawn flat (no 3D layers), with the base centred under the lid.
- **The reach background** (`src/hero-bg/reach*.ts`, the default look, `?bg=reach`) is concept 21's original art, the halftone fingertip reaching for a crisp pointer with one ember dot where they nearly touch, reusing the first hero's field and shapes (`src/scripts/art/`). It is full-bleed behind the hero: the arm runs in from the left edge and the fingertip meets the pointer just above the MacBook, in the corner above the phone on wide screens. Every ~7 s they drift together; at contact the ember sparks and a bone halftone shockwave crosses the whole field, the glow lingers, and they ease apart. The art and the stars lean a little toward the pointer or finger, dust drifts, and a click or tap on an empty part of the hero sends an extra pulse. Dots stay out from behind every text block and header control (the old hero's quiet zones), so text contrast is that of bone on void. It draws in a Web Worker on an OffscreenCanvas (on the page if that isn't available) at ≤ 30 fps (24 on phones), started after idle with a fade-in; paused off screen, on hidden tabs and by the pause button; Reduce Motion and Save-Data get one still frame of the contact. The worker is started through the one Trusted Types policy the CSP allows (`src/scripts/tt.ts`), which accepts only that worker's URL.
- **The hero background** (`src/hero-bg/`) is one WebGL quad behind the hero in one of three looks, chosen on the preview with `?bg=spectrum|aurora|bloom` (default `spectrum`): full-rainbow light curtains with some LED-dot columns, the same curtains in ember tones, or an ember bloom through an LED tile grid. The CSS poster shown from the first paint is generated at build time from the shader's own pattern code (`pattern.ts` → `poster.ts`, appended to the home stylesheet), so it is the shader's first frame and the fade-in reads as the picture coming to life. The shader starts in its own idle slot after the demo, renders at 0.6× (≤ 900k pixels; the bloom's LED grid is snapped to render pixels), draws at ≤ 30 fps (24 on phones), pauses off screen, on hidden tabs and with the pause button (keeping its last frame), and rebuilds itself after a lost WebGL context. Reduce Motion and Save-Data keep the poster and never create a WebGL context; turning motion back on starts it. Its hashes avoid `sin` of large numbers, so every GPU draws the same, stable picture. Motion state is cached, never read per frame: reading `matchMedia().matches` every frame swallows Chrome's media-query "change" event. Scrims keep the words readable (every hero text block measured ≥ 4.5:1 against the brightest pixel behind it, every look, 375 and 1280): a dark band under the header, a dark ellipse behind the text, solid plates under the small labels, and a dark backing behind the devices. The spectrum look deliberately breaks "ember only" (owner's choice, 30 Sep 2026). Drop `?bg=` once a look is chosen.
- **The footer** is fixed under the page and uncovered by an empty spacer after `main`, so it can never be shifted by the page reflowing above it. Its dot field (`src/scripts/footer.ts`) does nothing until the end of the page is within about two screens, then draws on one canvas (≤ 2× DPR, capped on very large screens) only while some of the footer shows: the "farside" dots assemble as the page lifts, lean toward an ember that follows the pointer (or wanders), and a click or tap sends a shockwave. Reduce Motion, Save-Data or the pause button get one still frame. Viewports under 620 px tall, or footers whose links don't fit, fall back to a normal footer that follows the page.
- The step, feature and 404 art are rendered once at build time. Scroll reveals (`src/scripts/reveal.ts`) only move blocks that start below the fold (transform only, never opacity), and do nothing for Reduce Motion or Save-Data.

## Tooling on the WSL box

The snap build of bun can't start the Playwright Chromium (its sandbox hides `libnspr4`). Use the plain bun in `~/.bun/bin` and point `CHROME_PATH` at `~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell`. Lighthouse's chrome-launcher also detects WSL and wants a Windows temp folder: put any `/mnt/c/Users/<you>/AppData/...` folder on `PATH` and add `--user-data-dir=/tmp/…` to its Chrome flags.
- Off-screen sections use `content-visibility: auto`.
- **Headers** (`_headers`): strict CSP (`default-src 'none'`, self scripts, Google Fonts only, Trusted Types with one named policy that only starts the reach worker), HSTS, `X-Frame-Options: DENY`, `nosniff`, referrer and permissions policies, COOP.

## Lighthouse (13.5.0, local server, SITE_URL set to the test origin)

See `reports/lighthouse/summary.md` after `bun run lighthouse` (git-ignored). Last run (30 Sep 2026, `website/launch-simple`): 100 / 100 / 100 / 100 (performance, accessibility, best practices, SEO) on mobile and desktop for every page except `/privacy` desktop (performance 99, CLS 0.075 from its short list reflowing on the font swap, unchanged from before this branch) and `/404` (SEO 66 by design: it is `noindex`, which Lighthouse scores as "not crawlable"). TBT 0 ms everywhere.

## Structured data

Each page carries one JSON-LD `@graph`: Organization (name "Farside", alternateName "Farside: Remote Desktop", legalName, logo, url, email; no `sameAs` until the getfarside social profiles exist), WebSite (alternateName "getfarside.com") and WebPage (or AboutPage, with a per-page `dateModified`), plus SoftwareApplication (with offers marked as planned while `pricing.final` is false), FAQPage, HowTo and BreadcrumbList where they apply. `bun run check` validates them. There are no ratings or reviews on purpose.

## Owner checklist

In `site.config.ts`: `SITE_URL`; `contact.*` (support, privacy, security and beta emails, legal name, governing law, response time; phone and postal address are optional and left out by the owner's decision of 30 Sep 2026, so `build:strict` passes with email-only contact); `social.*` (X, Instagram, Threads, TikTok profile URLs); `launch.*` (Mac DMG URL, App Store URL and ID, Mac version and SHA-256, and `launch.live`, the launch-day switch for the Smart App Banner, Apple's official App Store badge at `static/app-store-badge.svg` and the download links); `pricing.final`. Page dates for the sitemap, JSON-LD and "Updated" lines live in `src/pages/dates.ts`. Web help pages go under `/support/…`, never `/help/…` (the app claims `/help/*` as universal links; the build and `bun run check` refuse such pages). The HTML comments at the top of `/privacy`, `/terms` and `/support` list every `[TO FILL]` / `[CONFIRM]` item from the source documents.
