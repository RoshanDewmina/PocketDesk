// Every page the site publishes. The build, sitemap.xml, llms.txt, screenshots, Lighthouse runs and link
// checks all read this list, so adding a page here is enough to wire it everywhere.

import { comparePage } from "./compare";
import { controlGuidePage } from "./guide-control";
import { remoteGuidePage } from "./guide-remote";
import { trackpadGuidePage } from "./guide-trackpad";
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

export const PAGES: PageDef[] = [
  { slug: "home", path: "/", file: "index.html", render: homePage, sitemap: true },
  {
    slug: "control-mac-from-iphone",
    path: "/control-mac-from-iphone",
    file: "control-mac-from-iphone.html",
    render: controlGuidePage,
    sitemap: true,
    llms: { section: "Guides", title: "Control your Mac from your iPhone", note: "requirements, six setup steps, gestures, typing and voice, away from home, FAQ" },
  },
  {
    slug: "iphone-as-mac-trackpad",
    path: "/iphone-as-mac-trackpad",
    file: "iphone-as-mac-trackpad.html",
    render: trackpadGuidePage,
    sitemap: true,
    llms: { section: "Guides", title: "Use your iPhone as a Mac trackpad", note: "every gesture, click haptics, the pointer, zoom, keyboard and voice, FAQ" },
  },
  {
    slug: "remote-desktop-for-mac",
    path: "/remote-desktop-for-mac",
    file: "remote-desktop-for-mac.html",
    render: remoteGuidePage,
    sitemap: true,
    llms: { section: "Guides", title: "Remote desktop for Mac", note: "free on your own network, the Anywhere plan over the internet, how the encrypted connection works, limits, FAQ" },
  },
  {
    slug: "compare",
    path: "/compare",
    file: "compare.html",
    render: comparePage,
    sitemap: true,
    llms: { section: "Guides", title: "Farside compared", note: "feature table against Astropad Workbench, Jump Desktop, Screens 5 and Remote Mac Desktop Control, as of 28 September 2026, with sources" },
  },
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
    llms: { section: "Legal", title: "Terms of use (draft)", note: "draft, not yet in effect" },
  },
  { slug: "404", path: "/404", file: "404.html", render: notFoundPage, sitemap: false },
];
