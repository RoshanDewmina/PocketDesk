// JSON-LD (schema.org) builders. Every page gets one @graph: Organization + WebSite + the page's own nodes,
// linked by @id so search engines read them as one entity set.

import { config } from "../../site.config";
import type { Html } from "../lib/html";
import { updated } from "./dates";

type Node = Record<string, unknown>;

const url = (path = "/") => `${config.SITE_URL}${path}`;
export const ids = {
  org: () => url("/#organization"),
  site: () => url("/#website"),
  app: () => url("/#app"),
};

export function socialLinks(): string[] {
  return Object.values(config.social).filter((v): v is string => !!v);
}

/** The publisher. sameAs stays out until the getfarside social profiles exist (config.social). */
export function organization(): Node {
  const sameAs = socialLinks();
  const email = config.contact.supportEmail;
  return {
    "@type": "Organization",
    "@id": ids.org(),
    name: "Farside",
    alternateName: "Farside: Remote Desktop",
    ...(config.contact.legalName ? { legalName: config.contact.legalName } : {}),
    url: url("/"),
    logo: { "@type": "ImageObject", url: url("/icon-512.png"), width: 512, height: 512 },
    ...(email ? { email } : {}),
    ...(sameAs.length ? { sameAs } : {}),
    ...(email ? { contactPoint: { "@type": "ContactPoint", contactType: "customer support", email, url: url("/support") } } : {}),
  };
}

export function website(): Node {
  return { "@type": "WebSite", "@id": ids.site(), url: url("/"), name: "Farside", alternateName: "getfarside.com", inLanguage: "en", publisher: { "@id": ids.org() } };
}

export function softwareApplication(image: string): Node {
  const P = config.pricing;
  const note = P.final ? "" : " Planned launch price (draft); the App Store shows the final price in your currency.";
  const offer = (name: string, price: string, description: string) => ({
    "@type": "Offer",
    name,
    price,
    priceCurrency: P.currency,
    description: description + note,
    url: url("/#pricing"),
  });
  return {
    "@type": "SoftwareApplication",
    "@id": ids.app(),
    name: "Farside",
    alternateName: "Farside: Remote Desktop",
    description:
      "See and control your own Mac from your iPhone or iPad, with Farside for Mac running on the Mac. The whole screen is a trackpad with click haptics, a big sharp pointer, zoom that follows you, voice dictation into the Mac and a clipboard that goes both ways. QR pairing with no account, encrypted end to end.",
    url: url("/"),
    image: url(image),
    applicationCategory: "UtilitiesApplication",
    applicationSubCategory: "Remote desktop",
    operatingSystem: "iOS 26, iPadOS 26, macOS 26",
    isAccessibleForFree: true,
    publisher: { "@id": ids.org() },
    featureList: [
      "The whole screen is a trackpad, with click haptics",
      "Big, sharp pointer drawn by the phone",
      "Zoom that follows the pointer",
      "Voice dictation into the Mac",
      "Clipboard both ways",
      "QR pairing with no account",
      "Encrypted end to end",
    ],
    offers: [
      offer("Free at home", "0", "Free on the same local network as your Mac."),
      offer("Anywhere, monthly", P.monthlyAmount, `Access over the internet, after a ${P.trialDays}-day free trial.`),
      offer("Anywhere, yearly", P.yearlyAmount, `Access over the internet, after a ${P.trialDays}-day free trial.`),
    ],
  };
}

export function webPage(opts: { path: string; name: string; description: string; image: string; type?: string; breadcrumb?: boolean }): Node {
  return {
    "@type": opts.type ?? "WebPage",
    "@id": url(`${opts.path}#webpage`),
    url: url(opts.path),
    name: opts.name,
    description: opts.description,
    inLanguage: "en",
    isPartOf: { "@id": ids.site() },
    about: { "@id": ids.app() },
    primaryImageOfPage: { "@type": "ImageObject", url: url(opts.image) },
    dateModified: updated(opts.path),
    ...(opts.breadcrumb ? { breadcrumb: { "@id": url(`${opts.path}#breadcrumb`) } } : {}),
  };
}

export function breadcrumbs(path: string, trail: [string, string][]): Node {
  return {
    "@type": "BreadcrumbList",
    "@id": url(`${path}#breadcrumb`),
    itemListElement: trail.map(([name, p], i) => ({ "@type": "ListItem", position: i + 1, name, item: url(p) })),
  };
}

export type QA = { q: string; a: Html };

const text = (h: Html) =>
  h.value
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .replace(/ ([.,;:!?])/g, "$1")
    .trim();

export function faqPage(path: string, qas: QA[]): Node {
  return {
    "@type": "FAQPage",
    "@id": url(`${path}#faq`),
    mainEntity: qas.map(({ q, a }) => ({ "@type": "Question", name: q, acceptedAnswer: { "@type": "Answer", text: text(a) } })),
  };
}

export type Step = { name: string; text: string; image?: string };

export function howTo(path: string, opts: { name: string; description: string; steps: Step[]; tools?: string[]; totalTime?: string }): Node {
  return {
    "@type": "HowTo",
    "@id": url(`${path}#howto`),
    name: opts.name,
    description: opts.description,
    ...(opts.totalTime ? { totalTime: opts.totalTime } : {}),
    ...(opts.tools?.length ? { tool: opts.tools.map((name) => ({ "@type": "HowToTool", name })) } : {}),
    step: opts.steps.map((s, i) => ({
      "@type": "HowToStep",
      position: i + 1,
      name: s.name,
      text: s.text,
      url: url(`${path}#step-${i + 1}`),
      ...(s.image ? { image: url(s.image) } : {}),
    })),
  };
}

export function graph(...nodes: Node[]) {
  return { "@context": "https://schema.org", "@graph": [organization(), website(), ...nodes] };
}
