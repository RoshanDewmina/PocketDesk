import { config } from "../../site.config";
import { FONTS_URL } from "../lib/fonts";
import { esc, html, raw, type Html } from "../lib/html";
import { markSvg } from "../lib/mark";

export { FONTS_URL };

export type ImgAsset = { src: string; src2x: string; w: number; h: number; srcset?: string };

export type Assets = {
  /** The whole stylesheet, inlined in every page (no render-blocking request; allowed by its CSP hash). */
  cssText: string;
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
  /** Not-found page: no canonical URL of its own. */
  noCanonical?: boolean;
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
 * Download for Mac + App Store: live links after launch, "Coming soon" placeholders before.
 * At launch, swap the App Store placeholder for Apple's official badge artwork (Apple Marketing Resources).
 */
export function storeButtons(opts: { mac?: boolean } = {}): Html {
  const { macDownloadUrl, appStoreUrl } = config.launch;
  const mac = macDownloadUrl
    ? html`<a class="store" href="${macDownloadUrl}">${icon.mac}<span><small>Free download</small>Download for Mac</span></a>`
    : html`<span class="store">${icon.mac}<span><small>Coming soon</small>Download for Mac</span><span class="sr-only"> (not available yet)</span></span>`;
  const ios = appStoreUrl
    ? html`<a class="store" href="${appStoreUrl}">${icon.phone}<span><small>Download on the</small>App Store</span></a>`
    : html`<span class="store">${icon.phone}<span><small>Soon on the</small>App Store</span><span class="sr-only"> (iPhone and iPad app, not available yet)</span></span>`;
  return html`<div class="stores">${opts.mac === false ? "" : mac}${ios}</div>`;
}

/** Visible breadcrumb trail; pair it with schema.breadcrumbs() in the page's JSON-LD. */
export function breadcrumbNav(trail: [string, string][]): Html {
  return html`<nav class="crumbs" aria-label="Breadcrumb"><ol role="list">${trail.map(([name, href], i) =>
    i === trail.length - 1 ? html`<li><span aria-current="page">${name}</span></li>` : html`<li><a href="${href}">${name}</a></li>`,
  )}</ol></nav>`;
}

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

function footer(): Html {
  const owner = config.contact.legalName ?? "Farside";
  const social = SOCIAL.filter(([key]) => config.social[key]);
  const support = config.contact.supportEmail;
  return html`<footer class="site-footer">
  <div class="w">
    <div class="foot-top">
      <a class="brand" href="/" aria-label="Farside home">${raw(markSvg(18))}<span class="wm" aria-hidden="true">farside</span></a>
      <p class="foot-tag">Your Mac is far. Your reach isn’t.</p>
    </div>
    <nav class="foot-nav" aria-label="Footer">
      <div><h2>Farside</h2><ul role="list">
        <li><a href="/#how">How it works</a></li>
        <li><a href="/#pricing">Pricing</a></li>
        <li><a href="/#faq">FAQ</a></li>
        <li><a href="/#beta">${config.copy.cta}</a></li>
      </ul></div>
      <div><h2>Guides</h2><ul role="list">
        ${GUIDES.map(([href, t]) => html`<li><a href="${href}">${t}</a></li>`)}
      </ul></div>
      <div><h2>Help</h2><ul role="list">
        <li><a href="/support">Support</a></li>
        <li><a href="/support#messages">What a message means</a></li>
        ${support ? html`<li><a href="mailto:${support}">${support}</a></li>` : ""}
        <li><a href="/privacy">Privacy policy</a></li>
        <li><a href="/terms">Terms of use (draft)</a></li>
      </ul></div>
      ${social.length
        ? html`<div><h2>Follow</h2><ul role="list">${social.map(([key, label]) => html`<li><a href="${config.social[key]!}" rel="me noopener">${label}</a></li>`)}</ul></div>`
        : ""}
    </nav>
    <div class="foot-fine">
      <p>© 2026 ${owner}. No cookies, no analytics and no ads on this site.</p>
      <p>Apple, Mac, iPhone, iPad and App Store are trademarks of Apple Inc., registered in the U.S. and other countries and regions. Farside is not affiliated with Apple. Other product names belong to their owners.</p>
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
  const banner = config.launch.appStoreId ? html`\n<meta name="apple-itunes-app" content="app-id=${config.launch.appStoreId}">` : "";
  const ld = meta.jsonLd
    ? raw(`\n<script type="application/ld+json">${JSON.stringify(meta.jsonLd).replace(/</g, "\\u003c")}</script>`)
    : "";
  const doc = html`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${meta.title}</title>
<meta name="description" content="${meta.description}">${meta.noCanonical ? "" : html`\n<link rel="canonical" href="${url}">`}
<meta name="theme-color" content="#050505">
<meta name="color-scheme" content="dark">
<link rel="icon" href="/favicon.ico" sizes="32x32">
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/site.webmanifest">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<noscript><link rel="stylesheet" href="${FONTS_URL}"></noscript>
<style>${raw(assets.cssText)}</style>
<script type="module" src="${assets.js[meta.script]}"></script>
<meta property="og:type" content="website">
<meta property="og:site_name" content="Farside">
<meta property="og:locale" content="en_CA">
<meta property="og:title" content="${ogTitle}">
<meta property="og:description" content="${meta.description}">
<meta property="og:url" content="${url}">
<meta property="og:image" content="${img}">
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
${footer()}
</body>
</html>
`;
  return doc.value;
}
