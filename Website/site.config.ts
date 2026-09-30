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
    monthly: "CA$5.99",
    yearly: "CA$49.99",
    yearlyPerMonth: "CA$4.17",
    yearlySaving: "30%",
    trialDays: 7,
    currency: "CAD",
    monthlyAmount: "5.99",
    yearlyAmount: "49.99",
  },

  /**
   * The beta sign-up form (#beta on the home page). Every "Join the beta" button leads there.
   * `action` is the Pages Function from the infra branch (Website/DEPLOY.md): JSON or plain form posts,
   * fields email, source (page name) and company (honeypot, always empty).
   */
  waitlist: {
    action: "/api/waitlist",
  },

  /** Short marketing lines that need the owner's sign-off before launch. */
  copy: {
    /** Label of every beta button (header, hero, guides, form). */
    cta: "Join the beta",
    /** Under the hero button. No dates until the launch date is public (`bun run check` blocks them). */
    availability: "Coming soon to the App Store.",
    /**
     * Beside the sign-up button. Canada's anti-spam law (CASL) needs it: what people get and that they can
     * unsubscribe. The backend stores a consent version (CONSENT in functions/api/waitlist.ts): bump it
     * whenever this wording changes.
     */
    consent: "We’ll email you a beta invite and launch news. Unsubscribe anytime.",
  },

  /** Planned minimum OS versions (STORE-LISTING.md). */
  requirements: {
    /** D35: Apple silicon only for 1.0. */
    mac: "macOS 26 or later on a Mac with Apple silicon (M1 or later)",
    /** iPhone and iPad share one requirement line on the home page. */
    iphone: "iOS 26 or later",
    ipad: "iPadOS 26 or later",
  },

  /** Last content review of the legal pages. */
  legalUpdated: "29 September 2026",
  lastmod: "2026-09-29",
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
