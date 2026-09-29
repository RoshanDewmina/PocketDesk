# Farside website

Static marketing site for Farside, built to `design/FARSIDE-DESIGN-SYSTEM.md` and concept 21 · Reach. Dark only, no cookies, no analytics, no runtime dependencies. Deploys to Cloudflare Pages as plain files.

## Pages

| Path | What |
|---|---|
| `/` | Halftone hero (fingertip meets pointer), how it works, features, the "agent needs you" beta, pricing, FAQ, guides, beta sign-up |
| `/control-mac-from-iphone` | Step-by-step guide (HowTo + FAQ structured data) |
| `/iphone-as-mac-trackpad` | Gestures, haptics, pointer, zoom (HowTo + FAQ) |
| `/remote-desktop-for-mac` | At home vs the Anywhere plan, how the connection works, limits (HowTo + FAQ) |
| `/compare` | Dated, sourced table vs Astropad Workbench, Jump Desktop, Screens 5, Remote Mac Desktop Control |
| `/support` | Setup, gestures, can't-connect checklist, every app message with its fix, billing, contact |
| `/privacy` | From `Docs/launch/PRIVACY-POLICY.md` §2; owner checklist in an HTML comment |
| `/terms` | Draft terms, clearly marked as not in effect; owner checklist in an HTML comment |
| `/404` | Served by Pages for unknown paths |

Also generated: `sitemap.xml`, `robots.txt`, `llms.txt`, `site.webmanifest`, `_headers`, `_redirects`, favicon set, one 1200×630 Open Graph card per main page.

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

- **No render-blocking requests.** The stylesheet (≈35 KB) is inlined; the CSP allows it by SHA-256 hash (`scripts/build.ts` computes it). Scripts are deferred modules (home ≈ 13 KB, other pages ≈ 2 KB).
- **Fonts** (Geist, Geist Mono, Doto, Instrument Serif from Google Fonts, `display=swap`, preconnected) load right after the first paint. Local fallback faces in `src/styles/fallbacks.css` are tuned to the web fonts' metrics, so the swap doesn't move the layout; the hero's accent word and full stop have pinned widths.
- **The hero canvas** starts when the main thread is idle and draws in a Web Worker on an OffscreenCanvas (main-thread fallback when unsupported), at ≤ 30 fps, paused off-screen, on hidden tabs, with the on-page pause button, and replaced by a still frame for Reduce Motion or Save-Data. The step art and the 404 art are rendered once at build time.
- Off-screen sections use `content-visibility: auto`.
- **Headers** (`_headers`): strict CSP (`default-src 'none'`, self scripts and worker, Google Fonts only, Trusted Types with one named policy used to start the worker), HSTS, `X-Frame-Options: DENY`, `nosniff`, referrer and permissions policies, COOP.

## Lighthouse (13.5.0, local server, SITE_URL set to the test origin)

See `reports/lighthouse/summary.md` after `bun run lighthouse` (git-ignored). Last run: every page 100 / 100 / 100 / 100 (performance, accessibility, best practices, SEO) on mobile and desktop; mobile LCP 1.1–1.2 s, TBT 0 ms, CLS 0 (desktop: 0.001 on `/terms` and `/compare`, from the serif accent word's width changing when the web font arrives).

## Structured data

Each page carries one JSON-LD `@graph`: Organization, WebSite and WebPage, plus SoftwareApplication (with offers marked as planned while `pricing.final` is false), FAQPage, HowTo and BreadcrumbList where they apply. `bun run check` validates them. There are no ratings or reviews on purpose.

## Owner checklist

In `site.config.ts`: `SITE_URL`; `contact.*` (support, privacy, security and beta emails, phone, postal address, legal name, governing law, response time; Apple requires real contact details on the Support URL); `social.*` (X, Instagram, Threads, TikTok profile URLs); `launch.*` (Mac DMG URL, App Store URL and ID, Mac version and SHA-256); `pricing.final`. The HTML comments at the top of `/privacy`, `/terms` and `/support` list every `[TO FILL]` / `[CONFIRM]` item from the source documents.
