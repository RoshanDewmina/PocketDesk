// Renders the committed binary assets into static/ with headless Chrome, then rebuilds dist/:
//   static/og/og-<page>.png    1200×630 Open Graph cards from the hero halftone art (src/pages/og.ts)
//   static/apple-touch-icon.png, icon-192.png, icon-512.png   the app icon (concept 21)
//   static/favicon.ico         16 + 32 px, from the mark
//   static/img/*.webp          design previews cut from concept 21, latency figures removed
//
//   bun run assets                                  (concept path defaults to ../design/farside-round1/21-reach.html)
//   bun run assets -- --concept /path/to/21-reach.html
//   bun run assets -- --only og                     (og | icons | art | shots)
//   static/img/art-*.png       the "How it works" dither cards and the 404 scene (drawn once, not on phones)

import { existsSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { join, resolve } from "node:path";
import { html, raw } from "../src/lib/html";
import { markSvg } from "../src/lib/mark";
import { ARTS, SHOTS } from "../src/pages/images";
import { FONTS_URL } from "../src/pages/layout";
import { OG, ogFile } from "../src/pages/og";
import { build, ROOT } from "./build";
import { launch } from "./chrome";

const STATIC = join(ROOT, "static");
const arg = (n: string) => {
  const i = process.argv.indexOf(`--${n}`);
  return i > -1 ? process.argv[i + 1] : undefined;
};
const only = arg("only");
const want = (part: string) => !only || only === part;
const conceptPath = resolve(arg("concept") ?? process.env.CONCEPT ?? join(ROOT, "../design/farside-round1/21-reach.html"));

const { out, assets } = await build({ quiet: true });
const renderJs = await Bun.build({ entrypoints: [join(ROOT, "src/scripts/render.ts")], target: "browser", minify: true });
if (!renderJs.success) throw new AggregateError(renderJs.logs, "render bundle failed");
const renderCode = await renderJs.outputs[0]!.text();

const pdLine = (s: string) => s.replace(/\.$/, '<span class="pd">.</span>');

function ogPage(key: string) {
  const o = OG.find((x) => x.key === key)!;
  return html`<!doctype html><html lang="en"><head><meta charset="utf-8">
<link rel="stylesheet" href="${FONTS_URL}">
<style>${raw(assets.cssText)}
html,body{margin:0;background:var(--void)}
.og{position:relative;width:1200px;height:630px;overflow:hidden;background:var(--void)}
.og canvas{position:absolute;inset:0;width:1200px;height:630px}
.og-top{position:absolute;left:64px;top:54px;display:flex;align-items:center;gap:14px}
.og-top .wm{font-size:31px}
.og-k{position:absolute;left:64px;top:148px;font-size:15px}
.og h1{position:absolute;left:60px;top:186px;font:800 78px/1.06 var(--dot);letter-spacing:-.01em;white-space:nowrap;margin:0}
.og h1>span{display:block}
.og h1 em{font:400 italic 1.08em/1 var(--serif)}
.og-f{position:absolute;left:64px;bottom:52px;font-size:15px}
.og-gap{position:absolute;left:760px;top:292px;font:500 14px/1 var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--ash);background:var(--void);padding:7px 11px;border-radius:999px}
.og-gap b{color:var(--ember);font-weight:500}
</style></head><body>
<div class="og">
<canvas id="cv" width="1200" height="630"></canvas>
<div class="og-top">${raw(markSvg(28))}<span class="wm">farside</span></div>
<p class="cap og-k">${o.kicker}</p>
<h1><span>${raw(pdLine(o.line1))}</span><span>${o.line2}<em>${o.accent}</em></span></h1>
<p class="og-gap">Gap · <b>0 km · connected</b></p>
<p class="cap og-f">Control your Mac from iPhone · <b>Coming soon</b></p>
</div>
<script type="module">
import "/__render.js";
await document.fonts.ready;
const q = [...document.querySelectorAll(".og-top,.og-k,.og h1>span,.og-f,.og-gap")].map((el) => { const r = el.getBoundingClientRect(); return { x: r.left - 14, y: r.top - 14, w: r.width + 28, h: r.height + 28 }; });
window.farsideRender.og(document.getElementById("cv"), q);
window.__ready = true;
</script></body></html>`.value;
}

const server = Bun.serve({
  port: 0,
  async fetch(req) {
    const { pathname } = new URL(req.url);
    if (pathname === "/__render.js") return new Response(renderCode, { headers: { "Content-Type": "text/javascript" } });
    if (pathname.startsWith("/__og/")) return new Response(ogPage(pathname.slice(6)), { headers: { "Content-Type": "text/html" } });
    if (pathname === "/__blank")
      return new Response(`<!doctype html><html><body><script type="module">import "/__render.js"; window.__ready = true;</script></body></html>`, {
        headers: { "Content-Type": "text/html" },
      });
    const f = Bun.file(join(out, pathname));
    return (await f.exists()) ? new Response(f) : new Response("not found", { status: 404 });
  },
});
const base = `http://localhost:${server.port}`;
const browser = await launch();

const fromDataUrl = (u: string) => Buffer.from(u.slice(u.indexOf(",") + 1), "base64");

function ico(images: { size: number; data: Uint8Array }[]) {
  const head = Buffer.alloc(6 + 16 * images.length);
  head.writeUInt16LE(0, 0);
  head.writeUInt16LE(1, 2);
  head.writeUInt16LE(images.length, 4);
  let offset = head.length;
  images.forEach((img, i) => {
    const o = 6 + i * 16;
    head.writeUInt8(img.size >= 256 ? 0 : img.size, o);
    head.writeUInt8(img.size >= 256 ? 0 : img.size, o + 1);
    head.writeUInt16LE(1, o + 4);
    head.writeUInt16LE(32, o + 6);
    head.writeUInt32LE(img.data.length, o + 8);
    head.writeUInt32LE(offset, o + 12);
    offset += img.data.length;
  });
  return Buffer.concat([head, ...images.map((i) => Buffer.from(i.data))]);
}

try {
  if (want("og")) {
    await mkdir(join(STATIC, "og"), { recursive: true });
    for (const o of OG) {
      const page = await browser.newPage();
      await page.setViewport({ width: 1200, height: 630, deviceScaleFactor: 1 });
      await page.goto(`${base}/__og/${o.key}`, { waitUntil: "networkidle0" });
      await page.waitForFunction("window.__ready === true");
      const file = join(STATIC, ogFile(o.key));
      await page.screenshot({ path: file as `${string}.png`, clip: { x: 0, y: 0, width: 1200, height: 630 } });
      console.log(file);
      await page.close();
    }
  }

  if (want("icons")) {
    const page = await browser.newPage();
    await page.goto(`${base}/__blank`, { waitUntil: "networkidle0" });
    await page.waitForFunction("window.__ready === true");
    const icon = (px: number, cells: number) => page.evaluate((px, cells) => window.farsideRender.icon(px, cells), px, cells);
    await Bun.write(join(STATIC, "apple-touch-icon.png"), fromDataUrl(await icon(180, 20)));
    await Bun.write(join(STATIC, "icon-192.png"), fromDataUrl(await icon(192, 20)));
    await Bun.write(join(STATIC, "icon-512.png"), fromDataUrl(await icon(512, 30)));
    const fav = async (px: number) => fromDataUrl(await page.evaluate((px) => window.farsideRender.svg("/icon.svg", px), px));
    await Bun.write(join(STATIC, "favicon.ico"), ico([{ size: 16, data: await fav(16) }, { size: 32, data: await fav(32) }, { size: 48, data: await fav(48) }]));
    console.log("icons → static/apple-touch-icon.png, icon-192.png, icon-512.png, favicon.ico");
    await page.close();
  }

  await mkdir(join(STATIC, "img"), { recursive: true });
  const manifestPath = join(STATIC, "img/manifest.json");
  const manifest: Record<string, { w: number; h: number }> = existsSync(manifestPath) ? await Bun.file(manifestPath).json() : {};

  if (want("art")) {
    const page = await browser.newPage();
    await page.goto(`${base}/__blank`, { waitUntil: "networkidle0" });
    await page.waitForFunction("window.__ready === true");
    for (const a of ARTS) {
      const url = await page.evaluate((k) => window.farsideRender.art(k), a.key);
      const file = join(STATIC, `img/${a.key}.${a.ext}`);
      await Bun.write(file, fromDataUrl(url));
      manifest[a.key] = { w: a.w, h: a.h };
      console.log(file);
    }
    await page.close();
  }

  if (want("shots")) {
    if (!existsSync(conceptPath)) {
      console.warn(`concept not found at ${conceptPath}; skipping design previews (pass --concept <path>)`);
    } else {
      for (const dpr of [1, 2]) {
        const page = await browser.newPage();
        await page.setViewport({ width: 1800, height: 1200, deviceScaleFactor: dpr });
        await page.goto(`file://${conceptPath}#still`, { waitUntil: "networkidle0" });
        await page.evaluate(() => document.fonts.ready.then(() => true));
        await page.evaluate(() => {
          // No latency or frame-rate figures on the marketing site: strip them from the mock-ups.
          const set = (sel: string, text: string) =>
            document.querySelectorAll(sel).forEach((el) => {
              const last = el.lastChild;
              if (last && last.nodeType === Node.TEXT_NODE) last.textContent = text;
              else el.textContent = text;
            });
          set(".mac .st", "Awake · home Wi-Fi");
          set(".dk-f .cap", "Studio Mac · home Wi-Fi");
          set(".who small", "Home Wi-Fi");
          document.documentElement.style.setProperty("--ds", String(320 / 414));
          const css = document.createElement("style");
          css.textContent =
            "html,body{background:transparent!important}.w{max-width:1760px!important}.fit>.stage{transform:none!important}.fit{height:540px!important;overflow:visible!important}.grain{display:none!important}";
          document.head.appendChild(css);
        });
        await new Promise((r) => setTimeout(r, 400));
        for (const s of SHOTS) {
          const el = await page.$(s.selector);
          if (!el) throw new Error(`concept element not found: ${s.selector}`);
          const box = (await el.boundingBox())!;
          manifest[s.key] = { w: Math.round(box.width), h: Math.round(box.height) };
          const file = join(STATIC, `img/${s.key}${dpr === 2 ? "@2x" : ""}.webp`);
          await el.screenshot({ path: file as `${string}.webp`, type: "webp", quality: 82, omitBackground: true });
          console.log(file, manifest[s.key]);
        }
        await page.close();
      }
    }
  }
  await Bun.write(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
} finally {
  await browser.close();
  server.stop(true);
}

await build();
