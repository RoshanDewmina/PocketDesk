#!/usr/bin/env bun
// Farside social kit renderer. Headless Chrome (CDP) + ffmpeg, no npm dependencies.
//   bun design/social/render.ts all                 stills + videos + copy + index + verify
//   bun design/social/render.ts stills [id ...]     PNG stills (avatar, banner, posts, carousels, cheat sheet)
//   bun design/social/render.ts videos [id ...]     MP4s + cover PNGs
//   bun design/social/render.ts frames <id> t1,t2   debug PNG frames of one video into $FS_TMP
//   bun design/social/render.ts copy                copy/*.md and index.html
//   bun design/social/render.ts verify              sizes, codecs, durations, safe zones
// Env: FS_OUT (default ~/Downloads/farside-social), FS_TMP (Chrome profile + debug frames), FS_JOBS (parallel pages, default 3)
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync, copyFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { pathToFileURL } from "node:url";
import { STILLS, VIDEOS } from "./content.mjs";
import { buildCopy } from "./build-copy.mjs";

const ROOT = dirname(new URL(import.meta.url).pathname);
const OUT = resolve(process.env.FS_OUT || join(homedir(), "Downloads/farside-social"));
const TMP = resolve(process.env.FS_TMP || tmpdir());
const JOBS = Math.max(1, +(process.env.FS_JOBS || 3));
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const FFMPEG = process.env.FFMPEG || "ffmpeg";

type Msg = { id?: number; method?: string; params?: any; result?: any; error?: any; sessionId?: string };

class CDP {
  ws!: WebSocket;
  seq = 0;
  pending = new Map<number, { res: (v: any) => void; rej: (e: any) => void; m: string }>();
  listeners: ((m: Msg) => void)[] = [];
  proc: any;
  dir = "";
  async launch() {
    mkdirSync(TMP, { recursive: true });
    this.dir = mkdtempSync(join(TMP, "fs-chrome-"));
    this.proc = spawn(CHROME, [
      "--headless=new", "--remote-debugging-port=0", `--user-data-dir=${this.dir}`, "--no-first-run", "--no-default-browser-check",
      "--hide-scrollbars", "--force-color-profile=srgb", "--disable-lcd-text", "--font-render-hinting=none", "--allow-file-access-from-files",
      "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
      "--mute-audio", "--window-size=2000,2000", "about:blank",
    ], { stdio: ["ignore", "ignore", "pipe"] });
    this.proc.stderr.on("data", () => {});
    const pf = join(this.dir, "DevToolsActivePort");
    for (let i = 0; i < 400 && !existsSync(pf); i++) await Bun.sleep(25);
    if (!existsSync(pf)) throw new Error("Chrome did not start");
    const [port, path] = readFileSync(pf, "utf8").trim().split("\n");
    this.ws = new WebSocket(`ws://127.0.0.1:${port}${path}`);
    await new Promise<void>((res, rej) => { this.ws.onopen = () => res(); this.ws.onerror = (e) => rej(e); });
    this.ws.onmessage = (ev) => {
      const m: Msg = JSON.parse(String(ev.data));
      if (m.id != null && this.pending.has(m.id)) {
        const p = this.pending.get(m.id)!; this.pending.delete(m.id);
        m.error ? p.rej(new Error(`${p.m}: ${m.error.message}`)) : p.res(m.result);
      } else for (const l of this.listeners) l(m);
    };
  }
  send(method: string, params: any = {}, sessionId?: string): Promise<any> {
    const id = ++this.seq;
    this.ws.send(JSON.stringify({ id, method, params, sessionId }));
    return new Promise((res, rej) => this.pending.set(id, { res, rej, m: method }));
  }
  async close() {
    try { await this.send("Browser.close"); } catch {}
    try { this.proc.kill(); } catch {}
    await Bun.sleep(200);
    try { rmSync(this.dir, { recursive: true, force: true }); } catch {}
  }
}

class Page {
  constructor(public cdp: CDP, public sid: string, public tid: string) {}
  static async open(cdp: CDP, w: number, h: number) {
    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    const p = new Page(cdp, sessionId, targetId);
    await p.s("Page.enable"); await p.s("Runtime.enable");
    cdp.listeners.push((m) => {
      if (m.sessionId !== sessionId) return;
      if (m.method === "Runtime.exceptionThrown") console.error("  [page error]", m.params.exceptionDetails?.exception?.description || m.params.exceptionDetails?.text);
      if (m.method === "Runtime.consoleAPICalled" && (m.params.type === "error" || m.params.type === "warning")) console.error("  [console]", m.params.args.map((a: any) => a.value ?? a.description).join(" "));
    });
    await p.size(w, h);
    return p;
  }
  s(method: string, params: any = {}) { return this.cdp.send(method, params, this.sid); }
  async size(w: number, h: number) {
    await this.s("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: false, screenWidth: w, screenHeight: h });
    await this.s("Emulation.setDefaultBackgroundColorOverride", { color: { r: 5, g: 5, b: 5, a: 1 } });
  }
  async goto(url: string) {
    const loaded = new Promise<void>((res) => {
      const l = (m: Msg) => { if (m.sessionId === this.sid && m.method === "Page.loadEventFired") { this.cdp.listeners.splice(this.cdp.listeners.indexOf(l), 1); res(); } };
      this.cdp.listeners.push(l);
    });
    await this.s("Page.navigate", { url });
    await loaded;
    const r = await this.eval("window.__ready ? window.__ready.then(()=>true) : false", true);
    if (r !== true) throw new Error(`page not ready: ${url}`);
  }
  async eval(expr: string, awaitPromise = false) {
    const r = await this.s("Runtime.evaluate", { expression: expr, awaitPromise, returnByValue: true });
    if (r.exceptionDetails) throw new Error(`eval failed: ${expr}: ${r.exceptionDetails.exception?.description || r.exceptionDetails.text}`);
    return r.result?.value;
  }
  async shot(w: number, h: number, fast = false): Promise<Buffer> {
    const { data } = await this.s("Page.captureScreenshot", { format: "png", clip: { x: 0, y: 0, width: w, height: h, scale: 1 }, optimizeForSpeed: fast });
    return Buffer.from(data, "base64");
  }
  async pdf(wIn: number, hIn: number): Promise<Buffer> {
    const { data } = await this.s("Page.printToPDF", { paperWidth: wIn, paperHeight: hIn, printBackground: true, marginTop: 0, marginBottom: 0, marginLeft: 0, marginRight: 0, preferCSSPageSize: true });
    return Buffer.from(data, "base64");
  }
  close() { return this.cdp.send("Target.closeTarget", { targetId: this.tid }); }
}

const fileUrl = (p: string, q: Record<string, any> = {}) => {
  const u = pathToFileURL(join(ROOT, p));
  for (const [k, v] of Object.entries(q)) u.searchParams.set(k, String(v));
  return u.href;
};
const ensureDir = (f: string) => mkdirSync(dirname(f), { recursive: true });

async function pool<T>(items: T[], n: number, fn: (x: T) => Promise<void>) {
  const q = items.slice(); const runners = Array.from({ length: Math.min(n, q.length) }, async () => { while (q.length) await fn(q.shift()!); });
  await Promise.all(runners);
}

function pickStills(ids: string[]) { return ids.length ? STILLS.filter((s: any) => ids.some((i) => s.id === i || s.id.startsWith(i))) : STILLS; }
function pickVideos(ids: string[]) { return ids.length ? VIDEOS.filter((v: any) => ids.some((i) => v.id === i || v.id.startsWith(i))) : VIDEOS; }

async function renderStills(cdp: CDP, ids: string[]) {
  const list = pickStills(ids);
  const ordered = [...list.filter((s: any) => !s.after), ...list.filter((s: any) => s.after)];
  const first = ordered.filter((s: any) => !s.after), later = ordered.filter((s: any) => s.after);
  for (const group of [first, later]) {
    await pool(group, JOBS, async (s: any) => {
      const t0 = performance.now();
      const p = await Page.open(cdp, s.w, s.h);
      try {
        await p.goto(fileUrl(s.page || "stills.html", { id: s.id, w: s.w, h: s.h, out: OUT, ...(s.q || {}) }));
        const out = join(OUT, s.out);
        ensureDir(out);
        writeFileSync(out, await p.shot(s.w, s.h));
        if (s.pdf) { const pdfOut = join(OUT, s.pdf); ensureDir(pdfOut); writeFileSync(pdfOut, await p.pdf(s.w / 96, s.h / 96)); }
        console.log(`  still ${s.id.padEnd(22)} ${s.w}x${s.h}  ${((performance.now() - t0) / 1000).toFixed(1)}s  -> ${s.out}`);
      } finally { await p.close(); }
    });
  }
}

type SafeHit = { text: string; t: number; rect: number[] };

async function renderVideo(cdp: CDP, v: any) {
  const t0 = performance.now();
  const p = await Page.open(cdp, v.w, v.h);
  const safe: SafeHit[] = [];
  try {
    await p.goto(fileUrl(v.page, { render: 1, w: v.w, h: v.h, ...(v.q || {}) }));
    const spec = await p.eval("JSON.stringify(window.SPEC)");
    const S = JSON.parse(spec);
    const fps = v.fps || S.fps || 30, dur = v.dur || S.dur, N = Math.round(fps * dur);
    const out = join(OUT, v.out); ensureDir(out);
    const ff = spawn(FFMPEG, [
      "-y", "-loglevel", "error", "-f", "image2pipe", "-framerate", String(fps), "-c:v", "png", "-i", "-",
      "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
      "-map", "0:v", "-map", "1:a", "-t", String(dur),
      "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
      "-c:v", "libx264", "-preset", "slow", "-crf", String(v.crf || 17), "-maxrate", v.maxrate || "11M", "-bufsize", "22M",
      "-profile:v", "high", "-level", "4.2", "-r", String(fps), "-g", String(fps * 2),
      "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv", "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709:fullrange=off",
      "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", out,
    ], { stdio: ["pipe", "inherit", "inherit"] });
    const done = new Promise<number>((res) => ff.on("close", (c) => res(c ?? 1)));
    const write = (b: Buffer) => new Promise<void>((res) => { if (ff.stdin.write(b)) res(); else ff.stdin.once("drain", () => res()); });
    for (let f = 0; f < N; f++) {
      const t = f / fps;
      await p.eval(`window.seek(${t.toFixed(6)})`, true);
      await write(await p.shot(v.w, v.h, true));
      if (f % 3 === 0) {
        const hits: any[] = await p.eval("window.__safeCheck ? window.__safeCheck() : []");
        for (const h of hits) safe.push({ text: h.text, t, rect: h.rect });
      }
      if (v.cover != null && Math.abs(t - v.cover) < 0.5 / fps) {
        const cov = join(OUT, v.coverOut); ensureDir(cov); writeFileSync(cov, await p.shot(v.w, v.h));
      }
    }
    ff.stdin.end();
    const code = await done;
    if (code !== 0) throw new Error(`ffmpeg failed for ${v.id}`);
    const mb = statSync(out).size / 1e6;
    const uniq = new Map<string, SafeHit>();
    for (const s of safe) if (!uniq.has(s.text)) uniq.set(s.text, s);
    console.log(`  video ${v.id.padEnd(22)} ${v.w}x${v.h} ${fps}fps ${dur}s ${N}f  ${mb.toFixed(1)} MB  ${((performance.now() - t0) / 1000).toFixed(0)}s${uniq.size ? `  SAFE-ZONE HITS: ${uniq.size}` : ""}`);
    for (const s of uniq.values()) console.log(`     ! "${s.text}" at ${s.t.toFixed(2)}s rect=${s.rect.map((n) => Math.round(n)).join(",")}`);
    return { id: v.id, hits: [...uniq.values()] };
  } finally { await p.close(); }
}

async function renderVideos(cdp: CDP, ids: string[]) {
  const results: any[] = [];
  await pool(pickVideos(ids), JOBS, async (v) => { results.push(await renderVideo(cdp, v)); });
  const report = join(OUT, "copy", "_safe-zone-report.json"); ensureDir(report);
  let prev: any = {}; try { prev = JSON.parse(readFileSync(report, "utf8")); } catch {}
  for (const r of results) prev[r.id] = r.hits;
  writeFileSync(report, JSON.stringify(prev, null, 2));
}

async function debugFrames(cdp: CDP, id: string, times: number[]) {
  const v = VIDEOS.find((x: any) => x.id === id || x.id.startsWith(id));
  if (!v) throw new Error(`no video ${id}`);
  const p = await Page.open(cdp, v.w, v.h);
  try {
    await p.goto(fileUrl(v.page, { render: 1, w: v.w, h: v.h, ...(v.q || {}) }));
    const dir = join(TMP, "frames"); mkdirSync(dir, { recursive: true });
    for (const t of times) {
      await p.eval(`window.seek(${t})`, true);
      const f = join(dir, `${v.id}-${t.toFixed(2)}.png`);
      writeFileSync(f, await p.shot(v.w, v.h));
      const hits = await p.eval("window.__safeCheck ? window.__safeCheck() : []");
      console.log(`  ${f}${hits.length ? "  SAFE: " + hits.map((h: any) => h.text).join(" | ") : ""}`);
    }
  } finally { await p.close(); }
}

function probe(f: string) {
  const r = spawnSync("ffprobe", ["-v", "error", "-show_entries", "stream=codec_name,codec_type,width,height,r_frame_rate,pix_fmt,profile:format=duration,size,bit_rate", "-of", "json", f], { encoding: "utf8" });
  return JSON.parse(r.stdout || "{}");
}
function pngSize(f: string) {
  const b = readFileSync(f);
  if (b.readUInt32BE(0) !== 0x89504e47) return null;
  return [b.readUInt32BE(16), b.readUInt32BE(20)];
}

function verify() {
  let bad = 0;
  const line = (ok: boolean, s: string) => { if (!ok) bad++; console.log(`${ok ? "  ok " : "  !! "} ${s}`); };
  console.log("Stills:");
  for (const s of STILLS as any[]) {
    const f = join(OUT, s.out);
    if (!existsSync(f)) { line(false, `${s.out} missing`); continue; }
    const sz = pngSize(f);
    line(!!sz && sz[0] === s.w && sz[1] === s.h, `${s.out} ${sz?.join("x")} (want ${s.w}x${s.h}) ${(statSync(f).size / 1e3).toFixed(0)} KB`);
    if (s.pdf) line(existsSync(join(OUT, s.pdf)), `${s.pdf} present`);
  }
  console.log("Videos:");
  let report: any = {}; try { report = JSON.parse(readFileSync(join(OUT, "copy", "_safe-zone-report.json"), "utf8")); } catch {}
  for (const v of VIDEOS as any[]) {
    const f = join(OUT, v.out);
    if (!existsSync(f)) { line(false, `${v.out} missing`); continue; }
    const p = probe(f), vs = p.streams?.find((x: any) => x.codec_type === "video"), as = p.streams?.find((x: any) => x.codec_type === "audio");
    const dur = +p.format?.duration, mb = +p.format?.size / 1e6;
    const [fn, fd] = (vs?.r_frame_rate || "0/1").split("/").map(Number);
    const dec = spawnSync(FFMPEG, ["-v", "error", "-i", f, "-f", "null", "-"], { encoding: "utf8" });
    line(vs?.codec_name === "h264" && vs.width === v.w && vs.height === v.h && vs.pix_fmt === "yuv420p",
      `${v.out} ${vs?.codec_name} ${vs?.profile} ${vs?.width}x${vs?.height} ${vs?.pix_fmt} ${(fn / fd).toFixed(2)}fps ${dur.toFixed(2)}s ${mb.toFixed(1)}MB audio=${as?.codec_name}`);
    line(Math.abs(dur - v.dur) < 0.1, `  duration ${dur.toFixed(2)} ≈ ${v.dur}`);
    line(v.dur >= 7 && v.dur <= 20, `  length within 7-20 s`);
    line(mb < 20, `  under 20 MB`);
    line(dec.status === 0 && !dec.stderr.trim(), `  decodes cleanly end to end`);
    const hits = report[v.id];
    line(Array.isArray(hits) && hits.length === 0, `  safe-zone check ${Array.isArray(hits) ? hits.length + " hits" : "not run"}`);
    if (v.coverOut) { const c = join(OUT, v.coverOut); const sz = existsSync(c) ? pngSize(c) : null; line(!!sz && sz[0] === v.w && sz[1] === v.h, `  cover ${v.coverOut} ${sz?.join("x")}`); }
  }
  console.log(bad ? `\n${bad} problem(s)` : "\nAll checks passed");
  return bad;
}

async function main() {
  const [cmd = "all", ...rest] = process.argv.slice(2);
  mkdirSync(OUT, { recursive: true });
  if (cmd === "copy") { buildCopy(OUT, ROOT); return; }
  if (cmd === "verify") { process.exit(verify() ? 1 : 0); }
  const cdp = new CDP();
  await cdp.launch();
  try {
    if (cmd === "stills") await renderStills(cdp, rest);
    else if (cmd === "videos") await renderVideos(cdp, rest);
    else if (cmd === "frames") await debugFrames(cdp, rest[0], (rest[1] || "0").split(",").map(Number));
    else if (cmd === "all") { await renderStills(cdp, []); await renderVideos(cdp, []); }
    else throw new Error(`unknown command ${cmd}`);
  } finally { await cdp.close(); }
  if (cmd === "all") { buildCopy(OUT, ROOT); process.exit(verify() ? 1 : 0); }
}
main().catch((e) => { console.error(e); process.exit(1); });
