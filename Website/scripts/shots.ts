// Full-page screenshots of every page at desktop 1440 and mobile 390 (headless Chrome).
//   bun run shots                         → ~/Downloads/farside-site-<page>-<size>.png
//   bun run shots -- --out some/folder --viewport   (viewport-only captures, handy for quick looks)

import { homedir } from "node:os";
import { join } from "node:path";
import type { Page } from "puppeteer-core";
import { PAGES as REGISTRY } from "../src/pages/registry";
import { launch } from "./chrome";
import { startServer } from "./serve";

export const PAGES: [string, string][] = REGISTRY.map((p) => [p.slug, p.path]);

export const SIZES = [
  { name: "1440", width: 1440, height: 900, dpr: 1, mobile: false },
  { name: "390", width: 390, height: 844, dpr: 2, mobile: true },
];

export async function settle(page: Page) {
  await page.evaluate(() => document.fonts.ready.then(() => true));
  // Sections use content-visibility: auto, which a beyond-the-viewport capture never paints.
  // Force them visible for the screenshot only (CSSOM, so the page's CSP still applies).
  await page.evaluate(() => {
    document.querySelectorAll<HTMLElement>(".sec, .site-footer, .doc-sec").forEach((el) => (el.style.contentVisibility = "visible"));
  });
  // Walk down the page so lazy art paints, scroll reveals play and the demos start, then come back to the top.
  // "instant": the page asks for smooth scrolling, which would turn each jump into a slow glide.
  await page.evaluate(async () => {
    const step = window.innerHeight * 0.6;
    for (let y = 0; y < document.documentElement.scrollHeight; y += step) {
      window.scrollTo({ top: y, behavior: "instant" });
      await new Promise((r) => setTimeout(r, 140));
    }
    await new Promise((r) => setTimeout(r, 1200));
    window.scrollTo({ top: 0, behavior: "instant" });
  });
  // Let the hero finish its entrance and land the contact beat.
  await new Promise((r) => setTimeout(r, 2600));
}

if (import.meta.main) {
  const arg = (n: string) => {
    const i = process.argv.indexOf(`--${n}`);
    return i > -1 ? process.argv[i + 1] : undefined;
  };
  const out = arg("out") ?? join(homedir(), "Downloads");
  const viewportOnly = process.argv.includes("--viewport");
  const only = arg("pages")?.split(",");
  const { server } = await startServer({ port: 0, quiet: true });
  const base = `http://localhost:${server.port}`;
  const browser = await launch();
  try {
    for (const size of SIZES) {
      for (const [name, path] of PAGES) {
        if (only && !only.includes(name)) continue;
        const page = await browser.newPage();
        await page.setViewport({ width: size.width, height: size.height, deviceScaleFactor: size.dpr, isMobile: size.mobile, hasTouch: size.mobile });
        await page.goto(base + path, { waitUntil: "networkidle0" });
        await settle(page);
        const file = join(out, `farside-site-${name}-${size.name}.png`);
        if (!viewportOnly) {
          // Beyond-the-viewport capture repeats content under mobile emulation, so instead pin the
          // viewport-sized hero to its current height and grow the viewport to the whole document.
          const full = await page.evaluate(() => {
            document.querySelectorAll<HTMLElement>(".hero").forEach((h) => (h.style.minHeight = `${h.offsetHeight}px`));
            return document.documentElement.scrollHeight;
          });
          // Chrome can't capture more than ~16k device pixels in one go; lower the scale for long pages.
          const dpr = Math.min(size.dpr, Math.floor((16000 / full) * 100) / 100);
          await page.setViewport({ width: size.width, height: full, deviceScaleFactor: dpr, isMobile: size.mobile, hasTouch: size.mobile });
          await new Promise((r) => setTimeout(r, 700));
        }
        await page.screenshot({ path: file as `${string}.png` });
        console.log(file);
        await page.close();
      }
    }
  } finally {
    await browser.close();
    server.stop(true);
  }
}
