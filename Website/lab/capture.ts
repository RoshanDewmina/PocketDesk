// Key frames and short screen recordings of each hero-lab variant (headless Chrome, served with the site's
// real headers so the CSP applies).
//   bun lab/build.ts && bun lab/capture.ts --out <dir> [--video] [--only lid,pocket]

import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { launch } from "../scripts/chrome";
import { startServer } from "../scripts/serve";
import { ROOT } from "../scripts/build";

const arg = (n: string) => {
  const i = process.argv.indexOf(n);
  return i > -1 ? process.argv[i + 1] : undefined;
};
const out = arg("--out") ?? join(ROOT, "reports/hero-lab");
const only = arg("--only")?.split(",");
const video = process.argv.includes("--video");
const port = 4391;
await mkdir(out, { recursive: true });
const { server } = (await startServer({ dir: join(ROOT, "dist-lab"), port, quiet: true })) as unknown as { server?: { stop(): void } };

const SIZES = [
  { name: "desktop", width: 1280, height: 800, dpr: 1, mobile: false },
  { name: "375", width: 375, height: 812, dpr: 2, mobile: true },
];
const SHOTS: Record<string, number[]> = {
  lid: [0.4, 0.9, 1.4, 2.4, 3.6, 5.2, 6.3, 7.4, 9.0, 11.2, 13.2, 15.0, 16.6],
  pocket: [0.8, 2.2, 3.4, 4.6, 6.6, 8.2, 9.6, 11.4, 13.4],
  orbit: [1.2, 3.0, 4.6, 6.6, 8.6, 10.6, 12.6, 14.6, 16.4],
};

const browser = await launch();
const errors: string[] = [];
for (const size of SIZES) {
  for (const [id, times] of Object.entries(SHOTS)) {
    if (only && !only.includes(id)) continue;
    const page = await browser.newPage();
    page.on("console", (m) => { if (m.type() === "error" || m.type() === "warn") errors.push(`${id}/${size.name}: ${m.text()}`); });
    page.on("pageerror", (e) => errors.push(`${id}/${size.name}: ${e}`));
    await page.setViewport({ width: size.width, height: size.height, deviceScaleFactor: size.dpr, isMobile: size.mobile, hasTouch: size.mobile });
    await page.goto(`http://localhost:${port}/lab/${id}`, { waitUntil: "networkidle0" });
    await page.evaluate(() => document.fonts.ready.then(() => true));
    const rec = video && size.name === "desktop" ? await page.screencast({ path: join(out, `${id}-${size.name}.webm`) as `${string}.webm` }) : null;
    const since = await page.evaluate(() => performance.now());
    const t0 = Date.now() - since;
    for (const t of times) {
      const wait = t * 1000 - (Date.now() - t0);
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      await page.screenshot({ path: join(out, `${id}-${size.name}-${String(Math.round(t * 10)).padStart(3, "0")}.png`) as `${string}.png` });
    }
    if (rec) {
      await new Promise((r) => setTimeout(r, 2500));
      await rec.stop();
    }
    await page.close();
  }
  // Reduce Motion still frames.
  for (const id of Object.keys(SHOTS)) {
    if (only && !only.includes(id)) continue;
    const page = await browser.newPage();
    page.on("pageerror", (e) => errors.push(`${id}/${size.name}/still: ${e}`));
    await page.emulateMediaFeatures([{ name: "prefers-reduced-motion", value: "reduce" }]);
    await page.setViewport({ width: size.width, height: size.height, deviceScaleFactor: size.dpr, isMobile: size.mobile, hasTouch: size.mobile });
    await page.goto(`http://localhost:${port}/lab/${id}`, { waitUntil: "networkidle0" });
    await new Promise((r) => setTimeout(r, 600));
    await page.screenshot({ path: join(out, `${id}-${size.name}-still.png`) as `${string}.png` });
    await page.close();
  }
}
{
  const page = await browser.newPage();
  page.on("pageerror", (e) => errors.push(`index: ${e}`));
  await page.setViewport({ width: 1440, height: 1000 });
  await page.goto(`http://localhost:${port}/lab/hero-variants`, { waitUntil: "networkidle0" });
  await new Promise((r) => setTimeout(r, 7000));
  await page.screenshot({ path: join(out, "index-1440.png") as `${string}.png` });
  await page.close();
}
await browser.close();
server?.stop();
console.log(errors.length ? `console problems:\n${errors.join("\n")}` : "no console errors");
process.exit(0);
