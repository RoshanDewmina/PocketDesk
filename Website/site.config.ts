// Everything the owner must fill in before the site goes public lives in this file.
// `bun run build` prints what is still a placeholder; `bun run build:strict` refuses to build until nothing is.

import { WAITLIST_ENABLED } from "./edge/flags";

const PLACEHOLDER_SITE_URL = "https://farside.example";
const PRODUCTION_SITE_URL = "https://getfarside.com";

export type Contact = {
  /** Shown on /support and in the footer. Apple requires a real contact on the Support URL. */
  supportEmail: string | null;
  privacyEmail: string | null;
  securityEmail: string | null;
  /** Beta questions by email. */
  betaEmail: string | null;
  /**
   * Optional. The owner decided on 30 Sep 2026 to publish email-only contact (a Canadian site doesn't need a
   * phone or postal address); the pages leave these rows out while they are null.
   */
  phone: string | null;
  postalAddress: string | null;
  /** Legal entity or individual name (privacy policy "Who we are", terms, copyright line). */
  legalName: string | null;
  /** Governing law for the terms, e.g. "the Province of Ontario and the federal laws of Canada". */
  governingLaw: string | null;
  /** Promised first-reply time on /support, e.g. "within two business days". */
  responseTime: string | null;
};

export type Launch = {
  /**
   * Launch-day switch. false (now): no Smart App Banner, no App Store badge, no download links, even when the
   * URLs below are filled in. true: they all appear (the badge needs static/app-store-badge.svg, Apple's
   * official artwork from Apple Marketing Resources; the build refuses to go live without it).
   */
  live: boolean;
  /** URL of the notarized DMG (or the /download/mac/latest redirect target). null = "Coming soon". */
  macDownloadUrl: string | null;
  /** https://apps.apple.com/app/id<APP_ID>. null = "Coming soon". */
  appStoreUrl: string | null;
  /** Numeric App Store ID; turns on the Smart App Banner meta tag. */
  appStoreId: string | null;
  /** Mac companion version and SHA-256, shown next to the download when it exists. */
  macVersion: string | null;
  macSha256: string | null;
};

export type CtaStage = "follow" | "testflight" | "preorder";

export const config = {
  /**
   * The single URL placeholder. Set it to the real origin (https, no trailing slash) once the
   * domain is bought, then rebuild. Canonical links, Open Graph and Twitter tags, JSON-LD,
   * sitemap.xml, robots.txt and the _headers noindex rule all derive from it.
   * `SITE_URL=https://example.com bun run build` overrides it for one build.
   */
  SITE_URL: (process.env.SITE_URL ?? PRODUCTION_SITE_URL).replace(/\/+$/, ""),

  contact: {
    supportEmail: "support@getfarside.com",
    privacyEmail: "privacy@getfarside.com",
    securityEmail: "security@getfarside.com",
    betaEmail: "beta@getfarside.com",
    phone: null,
    postalAddress: null,
    legalName: "Roshan Silva Pulle",
    governingLaw: "the Province of Ontario and the federal laws of Canada applicable there",
    responseTime: "within two business days",
  } satisfies Contact as Contact,

  launch: {
    live: false,
    macDownloadUrl: null,
    appStoreUrl: null,
    appStoreId: null,
    macVersion: null,
    macSha256: null,
  } satisfies Launch as Launch,

  /**
   * Social profiles (footer links and Organization.sameAs in JSON-LD). Full https URLs.
   * null renders a "coming soon" placeholder and is left out of the structured data.
   */
  social: {
    x: null as string | null,
    instagram: null as string | null,
    threads: null as string | null,
    tiktok: null as string | null,
  },

  /**
   * Farside Anywhere pricing in Canadian dollars. Being re-decided before 23 Oct 2026, so no page, JSON-LD offer
   * or llms.txt line prints a price while `final` is false; the site says only that Anywhere is a paid plan.
   */
  pricing: {
    final: false,
    monthly: "CA$7.99",
    yearly: "CA$59.99",
    yearlyPerMonth: "CA$5.00",
    yearlySaving: "37%",
    trialDays: 7,
    currency: "CAD",
    monthlyAmount: "7.99",
    yearlyAmount: "59.99",
  },

  /**
   * The call to action on every page (header button, hero, footer, FAQ), in three stages. Switching is this one
   * line (`stage`), then rebuild and deploy:
   *   follow      beta not out yet: "Beta coming soon. Follow @getfarside for the link." → followUrl
   *   testflight  public beta open: "Join the beta" → testflightUrl (the TestFlight public link)
   *   preorder    on the App Store: "Pre-order on the App Store" → appStoreUrl
   * `bun run build:strict` refuses to build while the active stage's URL is empty.
   */
  cta: {
    stage: "follow" as CtaStage,
    followUrl: "https://x.com/getfarside",
    testflightUrl: "",
    appStoreUrl: "",
  },

  /** The email waitlist is off (edge/flags.ts): no form on the site, and /api/waitlist answers 410. */
  waitlist: {
    enabled: WAITLIST_ENABLED,
  },

  /** Short marketing lines that need the owner's sign-off before launch. */
  copy: {
    /** No dates until the launch date is public (`bun run check` blocks them). */
    availability: "Coming soon to the App Store.",
  },

  /** Planned minimum OS versions (STORE-LISTING.md). */
  requirements: {
    /** D35: Apple silicon only for 1.0. */
    mac: "macOS 26 or later on a Mac with Apple silicon (M1 or later)",
    /** 1.0 is iPhone-only (owner, 1 Oct 2026): no published page prints `ipad`; only the held-back guides read it. */
    iphone: "iOS 26 or later",
    ipad: "iPadOS 26 or later",
  },

  /**
   * The one hero background and the one footer game everyone gets. Preview hosts (*.pages.dev, localhost) can
   * still compare the others with ?bg=reach|spectrum|aurora|bloom and ?game=breakout|reach|lander|snake.
   */
  look: {
    heroBackground: "bloom" as "reach" | "spectrum" | "aurora" | "bloom",
    footerGame: "breakout" as "breakout" | "reach" | "lander" | "snake",
  },

  /** Last content review of the legal pages. */
  legalUpdated: "1 October 2026",
  /**
   * The privacy policy's effective date, e.g. "27 October 2026": set it to the production deploy date in the
   * commit that goes live. `bun run build:prod` (the production build, DEPLOY.md) refuses to build while it is
   * null; preview builds show the build date in its place.
   */
  privacyEffective: null as string | null,
};

export const isPlaceholderSiteUrl = () => config.SITE_URL === PLACEHOLDER_SITE_URL;

const CTA_URL = { follow: "followUrl", testflight: "testflightUrl", preorder: "appStoreUrl" } as const;

/** The URL the active CTA stage links to ("" while it isn't set). */
export const ctaUrl = (): string => config.cta[CTA_URL[config.cta.stage]];

/** Values that must be real before a public deploy (`build:strict` fails while any is missing). */
const OPTIONAL_CONTACT = new Set(["phone", "postalAddress"]);

export function missingRequired(opts: { production?: boolean } = {}): string[] {
  const out: string[] = [];
  if (isPlaceholderSiteUrl()) out.push("SITE_URL");
  for (const [k, v] of Object.entries(config.contact)) if (v === null && !OPTIONAL_CONTACT.has(k)) out.push(`contact.${k}`);
  if (!/^https:\/\/\S+$/.test(ctaUrl())) out.push(`cta.${CTA_URL[config.cta.stage]} (cta.stage is "${config.cta.stage}")`);
  if (opts.production && !config.privacyEffective) out.push("privacyEffective (the production deploy date)");
  return out;
}

/** Launch links that are allowed to stay empty; the site shows "Coming soon" instead. */
export function pendingLaunch(): string[] {
  return [
    ...(config.launch.live ? [] : ["launch.live (App Store banner, badge and downloads off until launch day)"]),
    ...Object.entries(config.launch).filter(([, v]) => v === null).map(([k]) => `launch.${k}`),
    ...Object.entries(config.social).filter(([, v]) => v === null).map(([k]) => `social.${k}`),
    ...(config.pricing.final ? [] : ["pricing.final (no prices are shown until pricing is final)"]),
  ];
}
