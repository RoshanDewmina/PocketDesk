import { config } from "../../site.config";
import { FONTS_URL } from "../lib/fonts";
import { esc, html, raw, type Html } from "../lib/html";
import { markSvg } from "../lib/mark";

export { FONTS_URL };

export type ImgAsset = { src: string; src2x: string; w: number; h: number; srcset?: string };

export type Assets = {
  /** The shared stylesheet, inlined in every page (no render-blocking request; allowed by its CSP hash). */
  cssText: string;
  /** Home-only styles (hero demo, home sections), inlined after cssText on the home page only. */
  homeCss: string;
  js: { home: string; site: string };
  /** Versioned URL of each Open Graph image, keyed by page slug. */
  og: Record<string, string>;
  /** Content-hashed design-preview images, keyed by shot key (src/pages/images.ts). */
  img: Record<string, ImgAsset>;
};

export type PageMeta = {
  path: string;
  title: string;
  description: string;
  script: keyof Assets["js"];
  /** Open Graph image key (see src/pages/og.ts); defaults to "home". */
  og?: string;
  bodyClass?: string;
  ogTitle?: string;
  jsonLd?: unknown;
  current?: "support" | "privacy" | "terms" | "guides" | "compare";
  /** Not-found page: no canonical URL, no og:url, and noindex. */
  noCanonical?: boolean;
  /** Also inline home.css (the home page). */
  homeCss?: boolean;
};

export const abs = (path: string) => `${config.SITE_URL}${path}`;

export const ogUrl = (assets: Assets, key = "home") => assets.og[key] ?? assets.og.home!;

// ---------- small shared pieces ----------

export const icon = {
  arrow: raw(
    '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 12h13M13 6l6 6-6 6" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  ),
  mac: raw(
    '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M1.5 19.5h21"/></svg>',
  ),
  phone: raw(
    '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="6.5" y="2.5" width="11" height="19" rx="2.6"/><path d="M11 18.5h2"/></svg>',
  ),
  menu: raw(
    '<svg class="ico i-open" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M4 8h16M4 16h16"/></svg><svg class="ico i-close" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M6 6l12 12M18 6 6 18"/></svg>',
  ),
  pointer: raw(
    '<svg viewBox="0 0 26 36" aria-hidden="true" focusable="false"><path d="M2 2v28l7.5-7 5 11 5-2.3-5-10.7H25z" fill="#0A0A0A" stroke="#EDE8DF" stroke-width="2.4" stroke-linejoin="round"/></svg>',
  ),
  chevron: raw(
    '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M9 6l6 6-6 6"/></svg>',
  ),
};

type EmailKind = "support" | "privacy" | "security" | "beta";

/** A configured address becomes a mailto link; an unset one renders the agreed placeholder text. */
export function email(kind: EmailKind): Html {
  const addr = config.contact[`${kind}Email`];
  if (addr) return html`<a href="mailto:${addr}">${addr}</a>`;
  return html`<span class="placeholder">${kind}@&lt;domain&gt; (to be confirmed)</span>`;
}

/** Any other owner detail: the value, or "(to be confirmed)". */
export function detail(value: string | null, fallback: string): Html {
  return value ? html`${value}` : html`<span class="placeholder">${fallback} (to be confirmed)</span>`;
}

export function betaHref() {
  const addr = config.contact.betaEmail;
  return addr ? `mailto:${addr}?subject=${encodeURIComponent("Farside beta")}` : null;
}

/**
 * Farside for Mac + the App Store: "Coming soon" placeholders until launch day. With config.launch.live on,
 * the Mac download becomes a link and the App Store placeholder becomes Apple's official badge
 * (static/app-store-badge.svg, unmodified, at least 40 px high; scripts/build.ts refuses to go live without it).
 */
export function storeButtons(opts: { mac?: boolean } = {}): Html {
  const { live, macDownloadUrl, appStoreUrl } = config.launch;
  const mac = live && macDownloadUrl
    ? html`<a class="store" href="${macDownloadUrl}">${icon.mac}<span><small>Free download</small>Farside for Mac</span></a>`
    : html`<span class="store">${icon.mac}<span><small>Coming soon</small>Farside for Mac</span><span class="sr-only"> (not available yet)</span></span>`;
  const ios = live && appStoreUrl
    ? html`<a class="store-badge" href="${appStoreUrl}"><img src="/app-store-badge.svg" width="120" height="40" alt="Download on the App Store"></a>`
    : html`<span class="store">${icon.phone}<span><small>Soon on the</small>App Store</span><span class="sr-only"> (iPhone and iPad app, not available yet)</span></span>`;
  return html`<div class="stores">${opts.mac === false ? "" : mac}${ios}</div>`;
}

/** Visible breadcrumb trail; pair it with schema.breadcrumbs() in the page's JSON-LD. */
export function breadcrumbNav(trail: [string, string][]): Html {
  return html`<nav class="crumbs" aria-label="Breadcrumb"><ol role="list">${trail.map(([name, href], i) =>
    i === trail.length - 1 ? html`<li><span aria-current="page">${name}</span></li>` : html`<li><a href="${href}">${name}</a></li>`,
  )}</ol></nav>`;
}

/** Guide cards for the guide pages (the home page and the footer link to the guides too). */
export const GUIDES: [string, string, string][] = [
  ["/control-mac-from-iphone", "Control your Mac from your iPhone", "Set up in three steps, then steer with one thumb"],
  ["/iphone-as-mac-trackpad", "Use your iPhone as a Mac trackpad", "Every gesture, the haptics, the pointer and the zoom"],
  ["/remote-desktop-for-mac", "Remote desktop for Mac", "At home for free, over the internet with Anywhere"],
  ["/compare", "How Farside compares", "Workbench, Jump Desktop, Screens and more"],
];

/** Cards linking to the guides (internal links for readers and for search). */
export function guideCards(except?: string): Html {
  return html`<ul class="guides" role="list">${GUIDES.filter(([href]) => href !== except).map(
    ([href, t, s]) => html`<li><a href="${href}"><span><b>${t}</b><small>${s}</small></span>${icon.chevron}</a></li>`,
  )}</ul>`;
}

// ---------- header / footer ----------

const NAV: [string, string, PageMeta["current"]?][] = [
  ["/#how", "How it works"],
  ["/#pricing", "Pricing"],
  ["/#faq", "FAQ"],
  ["/support", "Support", "support"],
];

function navLinks(current: PageMeta["current"]) {
  return NAV.map(([href, label, key]) => html`<a href="${href}"${raw(key && key === current ? ' aria-current="page"' : "")}>${label}</a>`);
}

function header(meta: PageMeta): Html {
  return html`<header class="site-header">
  <div class="bar w">
    <a class="brand" href="/" aria-label="Farside home">${raw(markSvg(18))}<span class="wm" aria-hidden="true">farside</span></a>
    <nav class="nav-desk" aria-label="Main">${navLinks(meta.current)}</nav>
    <div class="bar-r">
      <p class="status" aria-hidden="true"><span>Your Mac</span><b><i class="live"></i><span class="st-t">Reaching</span></b></p>
      <a class="pill" href="/#beta">${config.copy.cta}</a>
      <details class="nav-mob">
        <summary aria-label="Menu">${icon.menu}</summary>
        <nav aria-label="Main menu">${navLinks(meta.current)}</nav>
      </details>
    </div>
  </div>
</header>`;
}

const SOCIAL: [keyof typeof config.social, string][] = [
  ["x", "X"],
  ["instagram", "Instagram"],
  ["threads", "Threads"],
  ["tiktok", "TikTok"],
];

const FOOT_GUIDES: [string, string][] = [
  ["/control-mac-from-iphone", "Control your Mac from iPhone"],
  ["/iphone-as-mac-trackpad", "iPhone as a Mac trackpad"],
  ["/remote-desktop-for-mac", "Remote desktop for Mac"],
  ["/compare", "Compare"],
];

/**
 * The end of every page: a full-screen footer that sits under the page and is uncovered as the content lifts
 * away. Its canvas (src/scripts/footer.ts) turns into a giant dotted "farside" that reaches for the pointer;
 * the links sit on solid plates so they stay readable over it. The text wordmark below the canvas is the
 * fallback without script and for Reduce Motion until the still frame is drawn.
 */
function footer(): Html {
  const owner = config.contact.legalName ?? "Farside";
  const social = SOCIAL.filter(([key]) => config.social[key]);
  const support = config.contact.supportEmail;
  const link = (href: string, label: string) => html`<li><a class="plate" href="${href}">${label}</a></li>`;
  return html`<footer class="site-footer" aria-labelledby="foot-title">
  <canvas class="foot-cv" aria-hidden="true"></canvas>
  <div class="foot-in w">
    <div class="foot-head">
      <h2 class="foot-tag plate" id="foot-title">Your Mac is far. Your reach <em>isn’t.</em></h2>
      <a class="cta" href="/#beta">${config.copy.cta}<span class="arr" aria-hidden="true">${icon.arrow}</span></a>
    </div>
    <div class="foot-mark"><p class="foot-wm" aria-hidden="true">farside</p></div>
    <nav class="foot-nav" aria-label="Footer">
      <ul role="list">
        ${link("/support", "Support")}
        ${link("/about", "About")}
        ${link("/privacy", "Privacy")}
        ${link("/terms", "Terms")}
        ${support ? html`<li><a class="plate" href="mailto:${support}">${support}</a></li>` : ""}
      </ul>
      <ul role="list" aria-label="Guides">
        ${FOOT_GUIDES.map(([href, t]) => link(href, t))}
        ${social.map(([key, label]) => html`<li><a class="plate" href="${config.social[key]!}" rel="me noopener">${label}</a></li>`)}
      </ul>
    </nav>
    <div class="foot-fine plate">
      <p>© 2026 ${owner}. No cookies, no analytics, no ads.</p>
      <p>Apple, Mac, iPhone, iPad and App Store are trademarks of Apple Inc., registered in the U.S. and other countries and regions. Farside is not affiliated with Apple.</p>
    </div>
  </div>
</footer>`;
}

/** Page name sent with a beta sign-up (the waitlist `source` field: [a-z0-9_-]). */
const GUIDE_PATHS = new Set(["/control-mac-from-iphone", "/iphone-as-mac-trackpad", "/remote-desktop-for-mac"]);
function sourceName(meta: PageMeta): string {
  if (meta.path === "/") return "home";
  if (GUIDE_PATHS.has(meta.path)) return "guide";
  const name = meta.path.replace(/^\//, "").replace(/[^a-z0-9_-]/g, "");
  return name || "site";
}

// ---------- document ----------

export function page(meta: PageMeta, assets: Assets, body: Html): string {
  const url = abs(meta.path);
  const ogTitle = meta.ogTitle ?? meta.title;
  const img = abs(ogUrl(assets, meta.og));
  const imgAlt = "A halftone fingertip meets a Mac pointer at one ember dot, beside the Farside headline.";
  // Smart App Banner, launch day only. app-argument must be a path the app claims (AASA: /open).
  const banner =
    config.launch.live && config.launch.appStoreId
      ? html`\n<meta name="apple-itunes-app" content="app-id=${config.launch.appStoreId}, app-argument=${abs("/open")}">`
      : "";
  const ld = meta.jsonLd
    ? raw(`\n<script type="application/ld+json">${JSON.stringify(meta.jsonLd).replace(/</g, "\\u003c")}</script>`)
    : "";
  const doc = html`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${meta.title}</title>
<meta name="description" content="${meta.description}">${meta.noCanonical ? html`\n<meta name="robots" content="noindex">` : html`\n<link rel="canonical" href="${url}">`}
<meta name="theme-color" content="#050505">
<meta name="color-scheme" content="dark">
<link rel="icon" href="/favicon.ico" sizes="32x32">
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/site.webmanifest">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<noscript><link rel="stylesheet" href="${FONTS_URL}"></noscript>
<style>${raw(assets.cssText)}</style>${meta.homeCss ? html`\n<style>${raw(assets.homeCss)}</style>` : ""}
<script type="module" src="${assets.js[meta.script]}"></script>
<meta property="og:type" content="website">
<meta property="og:site_name" content="Farside">
<meta property="og:locale" content="en_CA">
<meta property="og:title" content="${ogTitle}">
<meta property="og:description" content="${meta.description}">
${meta.noCanonical ? "" : html`<meta property="og:url" content="${url}">\n`}<meta property="og:image" content="${img}">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="${imgAlt}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${ogTitle}">
<meta name="twitter:description" content="${meta.description}">
<meta name="twitter:image" content="${img}">
<meta name="twitter:image:alt" content="${imgAlt}">${banner}${ld}
</head>
<body${raw(meta.bodyClass ? ` class="${esc(meta.bodyClass)}"` : "")} data-src="${sourceName(meta)}">
<a class="skip" href="#main">Skip to content</a>
${header(meta)}
<main id="main" tabindex="-1">
${body}
</main>
<div class="foot-space" aria-hidden="true"></div>
${footer()}
</body>
</html>
`;
  return doc.value;
}
