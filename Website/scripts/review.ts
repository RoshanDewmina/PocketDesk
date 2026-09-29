// Dev helper: captures a page as a series of viewport-sized tiles so each can be inspected at full size.
//   bun scripts/review.ts --page / --width 1440 --height 900 --out /tmp/review [--reduced]

import { join } from "node:path";
import { launch } from "./chrome";
import { startServer } from "./serve";
import { settle } from "./shots";

const arg = (n: string, d?: string) => {
  const i = process.argv.indexOf(`--${n}`);
  return i > -1 ? process.argv[i + 1]! : d!;
};
const path = arg("page", "/");
const width = Number(arg("width", "1440"));
const height = Number(arg("height", "900"));
const out = arg("out", "/tmp");
const dpr = Number(arg("dpr", width < 600 ? "2" : "1"));
const reduced = process.argv.includes("--reduced");

const { server } = await startServer({ port: 0, quiet: true });
const browser = await launch();
try {
  const page = await browser.newPage();
  if (reduced) await page.emulateMediaFeatures([{ name: "prefers-reduced-motion", value: "reduce" }]);
  await page.setViewport({ width, height, deviceScaleFactor: dpr, isMobile: width < 600, hasTouch: width < 600 });
  const errors: string[] = [];
  page.on("console", (m) => {
    if (m.type() === "error" || m.type() === "warn") errors.push(`${m.type()}: ${m.text()}`);
  });
  page.on("pageerror", (e) => errors.push(`pageerror: ${e}`));
  await page.goto(`http://localhost:${server.port}${path}`, { waitUntil: "networkidle0" });
  await settle(page);
  const total = await page.evaluate(() => document.documentElement.scrollHeight);
  const scrollW = await page.evaluate(() => document.documentElement.scrollWidth);
  const slug = path === "/" ? "home" : path.replace(/\W+/g, "");
  let i = 0;
  for (let y = 0; y < total; y += height) {
    const file = join(out, `${slug}-${width}-${String(i++).padStart(2, "0")}.png`) as `${string}.png`;
    await page.screenshot({ path: file, clip: { x: 0, y, width, height: Math.min(height, total - y) }, captureBeyondViewport: true });
    console.log(file);
  }
  console.log(`scrollHeight ${total}, scrollWidth ${scrollW} (viewport ${width})`);
  if (errors.length) console.log(errors.join("\n"));
} finally {
  await browser.close();
  server.stop(true);
}
