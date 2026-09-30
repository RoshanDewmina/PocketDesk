// Everything the owner must fill in before the site goes public lives in this file.
// `bun run build` prints what is still a placeholder; `bun run build:strict` refuses to build until nothing is.

const PLACEHOLDER_SITE_URL = "https://farside.example";

export type Contact = {
  /** Shown on /support and in the footer. Apple requires a real contact on the Support URL. */
  supportEmail: string | null;
  privacyEmail: string | null;
  securityEmail: string | null;
  /** Where "Join the beta" emails go. */
  betaEmail: string | null;
  /** Apple's Support URL rules ask for a phone number and a postal address as well as email. */
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

export const config = {
  /**
   * The single URL placeholder. Set it to the real origin (https, no trailing slash) once the
   * domain is bought, then rebuild. Canonical links, Open Graph and Twitter tags, JSON-LD,
   * sitemap.xml, robots.txt and the _headers noindex rule all derive from it.
   * `SITE_URL=https://example.com bun run build` overrides it for one build.
   */
  SITE_URL: (process.env.SITE_URL ?? PLACEHOLDER_SITE_URL).replace(/\/+$/, ""),

  contact: {
    supportEmail: null,
    privacyEmail: null,
    securityEmail: null,
    betaEmail: null,
    phone: null,
    postalAddress: null,
    legalName: null,
    governingLaw: null,
    responseTime: null,
  } satisfies Contact as Contact,

  launch: {
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

  /** Proposed pricing (PRODUCT D28, SUBSCRIPTION-SETUP.md). Shown as planned, in Canadian dollars. */
  pricing: {
    /** false = draft: offers carry a "planned price" note in JSON-LD and the page says "planned". */
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

  /** Planned minimum OS versions (STORE-LISTING.md). */
  requirements: {
    mac: "macOS 26 or later",
    iphone: "iOS 26 or later",
    ipad: "iPadOS 26 or later",
  },

  /** Last content review of the legal pages. */
  legalUpdated: "28 September 2026",
  lastmod: "2026-09-28",
};

export const isPlaceholderSiteUrl = () => config.SITE_URL === PLACEHOLDER_SITE_URL;

/** Values that must be real before a public deploy (`build:strict` fails while any is missing). */
export function missingRequired(): string[] {
  const out: string[] = [];
  if (isPlaceholderSiteUrl()) out.push("SITE_URL");
  for (const [k, v] of Object.entries(config.contact)) if (v === null) out.push(`contact.${k}`);
  return out;
}

/** Launch links that are allowed to stay empty; the site shows "Coming soon" instead. */
export function pendingLaunch(): string[] {
  return [
    ...Object.entries(config.launch).filter(([, v]) => v === null).map(([k]) => `launch.${k}`),
    ...Object.entries(config.social).filter(([, v]) => v === null).map(([k]) => `social.${k}`),
    ...(config.pricing.final ? [] : ["pricing.final (prices shown as planned)"]),
  ];
}
