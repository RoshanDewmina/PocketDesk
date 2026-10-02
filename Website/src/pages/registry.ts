// Every page the site publishes. The build, sitemap.xml, llms.txt, screenshots, Lighthouse runs and link
// checks all read this list, so adding a page here is enough to wire it everywhere.

import { aboutPage } from "./about";
import { homePage } from "./home";
import type { Assets } from "./layout";
import { notFoundPage } from "./notfound";
import { privacyPage } from "./privacy";
import { supportPage } from "./support";
import { termsPage } from "./terms";

export type PageDef = {
  slug: string;
  path: string;
  file: string;
  render: (assets: Assets) => string;
  sitemap: boolean;
  llms?: { section: "Guides" | "Help" | "Legal"; title: string; note: string };
};

// Web pages never live under /help/: the phone app claims /help/* as universal links (AASA), so such a page
// would open the app instead. Help goes under /support. scripts/build.ts enforces it.

// Held back for the beta launch (1 Oct 2026): the three guides (src/pages/guide-*.ts) and /compare name
// competitors and describe Anywhere, Away mode and encryption in ways the feature ledger says we can't claim yet.
// To publish one again, add its entry back here (and its date in dates.ts is still there).
export const PAGES: PageDef[] = [
  { slug: "home", path: "/", file: "index.html", render: homePage, sitemap: true },
  {
    slug: "support",
    path: "/support",
    file: "support.html",
    render: supportPage,
    sitemap: true,
    llms: { section: "Help", title: "Support", note: "setup, gestures, a can't-connect checklist, what every app message means, billing, contact" },
  },
  {
    slug: "privacy",
    path: "/privacy",
    file: "privacy.html",
    render: privacyPage,
    sitemap: true,
    llms: { section: "Legal", title: "Privacy policy", note: "no account, no ads, no tracking; what stays on your devices and what the servers see" },
  },
  {
    slug: "terms",
    path: "/terms",
    file: "terms.html",
    render: termsPage,
    sitemap: true,
    llms: { section: "Legal", title: "Terms of use", note: "using Farside with your own Mac, the Anywhere subscription, acceptable use, liability" },
  },
  { slug: "about", path: "/about", file: "about.html", render: aboutPage, sitemap: true },
  { slug: "404", path: "/404", file: "404.html", render: notFoundPage, sitemap: false },
];
