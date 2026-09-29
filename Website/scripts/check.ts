// Site checks on the built dist/ (run `bun run build` first):
//   - every page: title/description length, one h1, heading order, canonical + Open Graph + Twitter tags
//   - JSON-LD parses, and each node has the fields its schema.org type needs
//   - internal links and #anchors resolve; images have alt, width and height
//   - no horizontal scrolling at 360, 375, 390, 768, 1024 and 1440 px
//   - no console errors or CSP violations with the production headers applied
//   - copy rules: no "far side", no latency/fps figures, no raw [TO FILL]/[CONFIRM] markers on the page
//   - sitemap.xml, robots.txt, llms.txt and the CSP style hash agree with the pages
//   bun run check

import { join } from "node:path";
import { PAGES } from "../src/pages/registry";
import { DIST } from "./build";
import { launch } from "./chrome";
import { startServer } from "./serve";

const WIDTHS = [360, 375, 390, 768, 1024, 1440];
const errors: string[] = [];
const warn: string[] = [];
const fail = (m: string) => errors.push(m);

type Scan = {
  title: string;
  description: string;
  canonical: string | null;
  og: Record<string, string>;
  h: number[];
  h1: number;
  imgs: { src: string; alt: string | null; w: string | null; h: string | null }[];
  links: string[];
  ids: string[];
  ld: string[];
  text: string;
  styles: string[];
};

const { server } = await startServer({ port: 0, quiet: true });
const base = `http://localhost:${server.port}`;
const browser = await launch();
const scans = new Map<string, Scan>();

try {
  for (const p of PAGES) {
    const page = await browser.newPage();
    const problems: string[] = [];
    page.on("console", (m) => {
      if (m.type() === "error") problems.push(`console error: ${m.text()}`);
    });
    page.on("pageerror", (e) => problems.push(`page error: ${e}`));
    await page.evaluateOnNewDocument(() => {
      document.addEventListener("securitypolicyviolation", (e) => console.error(`CSP violation: ${e.violatedDirective} ${e.blockedURI}`));
    });
    await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 1, isMobile: true, hasTouch: true });
    const res = await page.goto(base + p.path, { waitUntil: "networkidle0" });
    if (res && res.status() !== 200) fail(`${p.path}: HTTP ${res.status()}`);
    await new Promise((r) => setTimeout(r, 1200));

    for (const w of WIDTHS) {
      await page.setViewport({ width: w, height: 900, deviceScaleFactor: 1, isMobile: w < 768, hasTouch: w < 768 });
      await new Promise((r) => setTimeout(r, 150));
      const over = await page.evaluate(() => {
        const d = document.documentElement;
        const wide = [...document.querySelectorAll<HTMLElement>("body *")]
          .filter((el) => el.getBoundingClientRect().right > d.clientWidth + 1 && getComputedStyle(el).position !== "fixed")
          .filter((el) => !el.closest(".hero, .grain, .site-footer .foot-wm"))
          .slice(0, 3)
          .map((el) => `${el.tagName.toLowerCase()}.${el.className}`);
        return { scroll: d.scrollWidth, client: d.clientWidth, wide };
      });
      if (over.scroll > over.client) fail(`${p.path} @${w}px: horizontal scroll (${over.scroll} > ${over.client}) ${over.wide.join(" ")}`);
    }

    const scan = (await page.evaluate(() => {
      const meta = (sel: string) => document.querySelector<HTMLMetaElement>(sel)?.content ?? "";
      const og: Record<string, string> = {};
      document.querySelectorAll<HTMLMetaElement>('meta[property^="og:"], meta[name^="twitter:"]').forEach((m) => (og[m.getAttribute("property") ?? m.name] = m.content));
      return {
        title: document.title,
        description: meta('meta[name="description"]'),
        canonical: document.querySelector<HTMLLinkElement>('link[rel="canonical"]')?.href ?? null,
        og,
        h: [...document.querySelectorAll("main h1, main h2, main h3, main h4, main h5, main h6")].map((h) => Number(h.tagName[1])),
        h1: document.querySelectorAll("h1").length,
        imgs: [...document.images].map((i) => ({ src: i.getAttribute("src") ?? "", alt: i.getAttribute("alt"), w: i.getAttribute("width"), h: i.getAttribute("height") })),
        links: [...document.querySelectorAll<HTMLAnchorElement>("a[href]")].map((a) => a.getAttribute("href")!),
        ids: [...document.querySelectorAll("[id]")].map((e) => e.id),
        ld: [...document.querySelectorAll('script[type="application/ld+json"]')].map((s) => s.textContent ?? ""),
        text: document.body.innerText,
        styles: [...document.querySelectorAll("style")].map((s) => s.textContent ?? ""),
      };
    })) as Scan;
    scans.set(p.path, scan);
    problems.forEach((m) => fail(`${p.path}: ${m}`));
    await page.close();
  }
} finally {
  await browser.close();
  server.stop(true);
}

// ---------- per-page content checks ----------
const known = new Set(PAGES.map((p) => p.path));
for (const [path, s] of scans) {
  const page = PAGES.find((p) => p.path === path)!;
  if (s.title.length < 15 || s.title.length > 65) warn.push(`${path}: title is ${s.title.length} characters`);
  if (s.description.length < 70 || s.description.length > 170) warn.push(`${path}: description is ${s.description.length} characters`);
  if (s.h1 !== 1) fail(`${path}: ${s.h1} h1 elements`);
  for (let i = 1; i < s.h.length; i++) if (s.h[i]! > s.h[i - 1]! + 1) fail(`${path}: heading jumps from h${s.h[i - 1]} to h${s.h[i]}`);
  if (page.sitemap && !s.canonical) fail(`${path}: no canonical`);
  for (const k of ["og:title", "og:description", "og:image", "og:url", "twitter:card", "twitter:image"]) if (!s.og[k]) fail(`${path}: missing ${k}`);
  if (s.og["og:image"] && !/^https?:\/\//.test(s.og["og:image"])) fail(`${path}: og:image is not absolute`);
  for (const img of s.imgs) {
    if (img.alt === null) fail(`${path}: image without alt ${img.src}`);
    if (!img.w || !img.h) fail(`${path}: image without width/height ${img.src}`);
  }
  // Links and anchors.
  for (const href of s.links) {
    if (/^(https?:|mailto:)/.test(href)) continue;
    const [p0, frag] = href.split("#");
    const target = p0 === "" ? path : p0!;
    if (!known.has(target)) {
      const f = Bun.file(join(DIST, target));
      if (!(await f.exists())) fail(`${path}: broken link ${href}`);
      continue;
    }
    if (frag && !scans.get(target)?.ids.includes(frag)) fail(`${path}: missing anchor ${href}`);
  }
  // Copy rules.
  if (/far side/i.test(s.text)) fail(`${path}: says "far side" (trademark caution)`);
  if (/\b\d+\s?(ms|fps)\b/i.test(s.text)) fail(`${path}: shows a latency or frame-rate figure`);
  if (/from anywhere/i.test(s.text)) fail(`${path}: says "from anywhere"`);
  if (/\[(TO FILL|CONFIRM)/.test(s.text)) fail(`${path}: raw [TO FILL]/[CONFIRM] marker visible on the page`);
  if (/\b(launch(es|ing)? on|available on) (\d|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)/i.test(s.text)) fail(`${path}: mentions a launch date`);
  // JSON-LD.
  for (const block of s.ld) {
    let data: any;
    try {
      data = JSON.parse(block);
    } catch (e) {
      fail(`${path}: JSON-LD does not parse (${e})`);
      continue;
    }
    if (data["@context"] !== "https://schema.org") fail(`${path}: JSON-LD @context`);
    const nodes: any[] = data["@graph"] ?? [data];
    for (const n of nodes) validateNode(path, n);
  }
}

function validateNode(path: string, n: any) {
  const need = (cond: unknown, what: string) => {
    if (!cond) fail(`${path}: JSON-LD ${n["@type"]} missing ${what}`);
  };
  const abs = (u: unknown) => typeof u === "string" && /^https?:\/\//.test(u);
  switch (n["@type"]) {
    case "Organization":
      need(n.name, "name");
      need(abs(n.url), "absolute url");
      need(abs(n.logo?.url), "logo.url");
      break;
    case "WebSite":
      need(n.name && abs(n.url), "name/url");
      break;
    case "WebPage":
      need(n.name && abs(n.url), "name/url");
      break;
    case "SoftwareApplication":
      need(n.name, "name");
      need(n.applicationCategory, "applicationCategory");
      need(n.operatingSystem, "operatingSystem");
      need(Array.isArray(n.offers) && n.offers.every((o: any) => o.price !== undefined && o.priceCurrency), "offers.price/priceCurrency");
      break;
    case "FAQPage":
      need(Array.isArray(n.mainEntity) && n.mainEntity.length, "mainEntity");
      for (const q of n.mainEntity ?? []) need(q["@type"] === "Question" && q.name && q.acceptedAnswer?.text, "Question name/acceptedAnswer.text");
      break;
    case "HowTo":
      need(n.name, "name");
      need(Array.isArray(n.step) && n.step.length >= 2, "at least two steps");
      for (const st of n.step ?? []) need(st["@type"] === "HowToStep" && st.text, "HowToStep text");
      break;
    case "BreadcrumbList":
      need(Array.isArray(n.itemListElement) && n.itemListElement.length >= 2, "two or more items");
      n.itemListElement?.forEach((it: any, i: number) => need(it.position === i + 1 && it.name && abs(it.item), "ordered items with absolute URLs"));
      break;
    default:
      fail(`${path}: JSON-LD has an unexpected @type ${n["@type"]}`);
  }
}

// ---------- site files ----------
const sitemap = await Bun.file(join(DIST, "sitemap.xml")).text();
for (const p of PAGES.filter((x) => x.sitemap)) if (!sitemap.includes(`${p.path}</loc>`)) fail(`sitemap.xml: missing ${p.path}`);
if (!/<lastmod>\d{4}-\d{2}-\d{2}<\/lastmod>/.test(sitemap)) fail("sitemap.xml: no lastmod");
const robots = await Bun.file(join(DIST, "robots.txt")).text();
if (!/^Sitemap: https?:\/\/.+\/sitemap\.xml$/m.test(robots)) fail("robots.txt: no absolute Sitemap line");
const llms = await Bun.file(join(DIST, "llms.txt")).text();
if (!llms.startsWith("# Farside")) fail("llms.txt: must start with '# Farside'");
const headers = await Bun.file(join(DIST, "_headers")).text();
const associationPath = ".well-known/apple-app-site-association";
const association = Bun.file(join(DIST, associationPath));
if (!(await association.exists())) fail(`${associationPath}: missing from dist`);
else {
  const expected = await Bun.file(join(import.meta.dir, "../static", associationPath)).text();
  if ((await association.text()) !== expected) fail(`${associationPath}: output differs from approved source`);
}
if (!/^\/\.well-known\/apple-app-site-association\n  Content-Type: application\/json$/m.test(headers)) {
  fail("_headers: AASA needs an exact-path application/json rule");
}
if (/^\/\.well-known\/apple-app-site-association\s+\S+/m.test(await Bun.file(join(DIST, "_redirects")).text())) {
  fail("_redirects: AASA must not redirect");
}
for (const [path, s] of scans) {
  for (const css of s.styles) {
    const hash = `sha256-${new Bun.CryptoHasher("sha256").update(css).digest("base64")}`;
    if (!headers.includes(`'${hash}'`)) fail(`${path}: inline <style> hash ${hash} is not in the CSP`);
  }
}

console.log(`checked ${scans.size} pages at ${WIDTHS.join(", ")} px`);
warn.forEach((w) => console.log(`warn: ${w}`));
if (errors.length) {
  errors.forEach((e) => console.log(`FAIL: ${e}`));
  process.exit(1);
}
console.log("all checks passed");
