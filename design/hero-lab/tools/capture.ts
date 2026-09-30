// Deterministic headless-Chrome frame capture over CDP with a virtual clock.
// usage: bun capture.ts <url> <outDir> [--w 540 --h 960 --dpr 2 --fps 30 --dur 5 --from 0 --css "<extra css>" --shots 0.5,1.2]
import { mkdirSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";

const argv = process.argv.slice(2);
const url = argv[0];
const outDir = argv[1];
const opt = (k: string, d: string) => {
  const i = argv.indexOf("--" + k);
  return i >= 0 ? argv[i + 1] : d;
};
const W = +opt("w", "540"), H = +opt("h", "960"), DPR = +opt("dpr", "2");
const FPS = +opt("fps", "30"), DUR = +opt("dur", "5"), FROM = +opt("from", "0");
const CSS = opt("css", "");
const SHOTS = opt("shots", "");
const PORT = 9300 + Math.floor(Math.random() * 500);
mkdirSync(outDir, { recursive: true });

const profile = `${process.env.TMPDIR || "/tmp"}/hl-cap-${PORT}`;
const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", [
  "--headless=new", `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`,
  "--no-first-run", "--no-default-browser-check", "--hide-scrollbars", "--mute-audio",
  "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
  `--window-size=${W},${H}`, "about:blank",
], { stdio: "ignore" });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
let wsUrl = "";
for (let i = 0; i < 100 && !wsUrl; i++) {
  try {
    const list = (await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json()) as any[];
    const p = list.find((t) => t.type === "page");
    if (p) wsUrl = p.webSocketDebuggerUrl;
  } catch {}
  if (!wsUrl) await sleep(100);
}
if (!wsUrl) { chrome.kill(); throw new Error("no CDP page"); }

const ws = new WebSocket(wsUrl);
await new Promise((r) => (ws.onopen = r));
let seq = 0;
const pending = new Map<number, (v: any) => void>();
ws.onmessage = (e) => {
  const m = JSON.parse(String(e.data));
  if (m.id && pending.has(m.id)) { pending.get(m.id)!(m); pending.delete(m.id); }
};
const send = (method: string, params: any = {}) =>
  new Promise<any>((res, rej) => {
    const id = ++seq;
    pending.set(id, (m) => (m.error ? rej(new Error(method + ": " + JSON.stringify(m.error))) : res(m.result)));
    ws.send(JSON.stringify({ id, method, params }));
  });
const evalJS = async (expr: string) => {
  const r = await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error("eval: " + JSON.stringify(r.exceptionDetails).slice(0, 400));
  return r.result?.value;
};

const SHIM = `(() => {
  let vnow = 0, rafQ = [], rafId = 0, timers = [], tid = 0;
  const epoch = Date.now();
  performance.now = () => vnow;
  Date.now = () => epoch + vnow;
  window.requestAnimationFrame = (cb) => { rafQ.push({ id: ++rafId, cb }); return rafId; };
  window.cancelAnimationFrame = (id) => { rafQ = rafQ.filter((r) => r.id !== id); };
  window.setTimeout = (cb, ms, ...a) => { timers.push({ id: ++tid, at: vnow + (+ms || 0), cb, a }); return tid; };
  window.clearTimeout = (id) => { timers = timers.filter((t) => t.id !== id); };
  const seen = new WeakMap();
  const syncAnims = () => {
    for (const a of document.getAnimations()) {
      if (!seen.has(a)) { seen.set(a, vnow); a.pause(); }
      a.currentTime = vnow - seen.get(a);
    }
  };
  window.__vt = {
    advance(ms) {
      vnow += ms;
      timers.sort((x, y) => x.at - y.at);
      while (timers.length && timers[0].at <= vnow) { const t = timers.shift(); try { t.cb(...t.a); } catch (e) { console.error(e); } }
      const q = rafQ; rafQ = [];
      for (const r of q) { try { r.cb(vnow); } catch (e) { console.error(e); } }
      syncAnims();
      return vnow;
    },
    now: () => vnow,
  };
})();`;

await send("Page.enable");
await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: DPR, mobile: W < 700 });
await send("Page.addScriptToEvaluateOnNewDocument", { source: SHIM });
await send("Page.navigate", { url });
for (let i = 0; i < 200; i++) {
  const rs = await evalJS("document.readyState").catch(() => "");
  if (rs === "complete") break;
  await sleep(100);
}
await evalJS("document.fonts.ready.then(() => true)");
await sleep(1500);
if (CSS) await evalJS(`(() => { const s = document.createElement('style'); s.textContent = ${JSON.stringify(CSS)}; document.head.appendChild(s); return true; })()`);
const fontInfo = await evalJS(`Promise.all(['800 16px "Doto"','700 16px "Geist"','500 16px "Geist"','400 16px "Geist Mono"','italic 400 16px "Instrument Serif"'].map(f => document.fonts.load(f).then(() => [f, document.fonts.check(f)]))).then(r => JSON.stringify(r))`);
console.log("fonts:", fontInfo);

const step = 1000 / FPS;
// run the clock up to FROM without capturing
let t = 0;
while (t + step <= FROM * 1000 + 1e-6) { await evalJS(`__vt.advance(${step})`); t += step; }

const shot = async (file: string) => {
  const r = await send("Page.captureScreenshot", { format: "png", fromSurface: true, captureBeyondViewport: false });
  writeFileSync(file, Buffer.from(r.data, "base64"));
};

if (SHOTS) {
  const times = SHOTS.split(",").map(Number).sort((a, b) => a - b);
  for (const ts of times) {
    while (t + step <= ts * 1000 + 1e-6) { await evalJS(`__vt.advance(${step})`); t += step; }
    await shot(`${outDir}/shot_${ts.toFixed(2)}.png`);
    console.log("shot", ts);
  }
} else {
  const n = Math.round(DUR * FPS);
  for (let i = 0; i < n; i++) {
    await evalJS(`__vt.advance(${step})`); t += step;
    await shot(`${outDir}/f_${String(i).padStart(5, "0")}.png`);
    if (i % 30 === 0) console.log("frame", i, "t=", (t / 1000).toFixed(2));
  }
}
ws.close();
chrome.kill();
console.log("done");
process.exit(0);
