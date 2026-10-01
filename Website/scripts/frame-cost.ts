// Dev helper: measures how long the page's animation-frame callbacks take (mobile emulation, real CPU), mostly
// the hero demo's, so they stay well under the 50 ms long-task line even with Lighthouse's 4x CPU slowdown.
//   bun scripts/frame-cost.ts [--width 412 --height 823 --dpr 1.75]

import { launch } from "./chrome";
import { startServer } from "./serve";

const arg = (n: string, d: string) => {
  const i = process.argv.indexOf(`--${n}`);
  return Number(i > -1 ? process.argv[i + 1] : d);
};
const { server } = await startServer({ port: 0, quiet: true });
const browser = await launch();
try {
  const page = await browser.newPage();
  await page.setViewport({ width: arg("width", "412"), height: arg("height", "823"), deviceScaleFactor: arg("dpr", "1.75"), isMobile: true, hasTouch: true });
  await page.evaluateOnNewDocument(() => {
    const w = window as unknown as { __frames: number[]; __tasks: number[] };
    w.__frames = [];
    w.__tasks = [];
    const raf = window.requestAnimationFrame.bind(window);
    window.requestAnimationFrame = (cb) =>
      raf((t) => {
        const s = performance.now();
        cb(t);
        w.__frames.push(performance.now() - s);
      });
    new PerformanceObserver((l) => l.getEntries().forEach((e) => w.__tasks.push(e.duration))).observe({ type: "longtask", buffered: true });
  });
  await page.goto(`http://localhost:${server.port}/`, { waitUntil: "load" });
  await new Promise((r) => setTimeout(r, 4000));
  const r = await page.evaluate(() => {
    const w = window as unknown as { __frames: number[]; __tasks: number[] };
    const f = w.__frames.filter((x) => x > 0.5).sort((a, b) => a - b);
    const pct = (p: number) => f[Math.min(f.length - 1, Math.floor(f.length * p))] ?? 0;
    return { frames: f.length, p50: pct(0.5), p90: pct(0.9), max: f[f.length - 1] ?? 0, longTasks: w.__tasks };
  });
  console.log(JSON.stringify(r, (_, v) => (typeof v === "number" ? Math.round(v * 10) / 10 : v)));
} finally {
  await browser.close();
  server.stop(true);
}
