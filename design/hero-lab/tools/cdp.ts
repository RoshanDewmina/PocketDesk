import { spawn } from "node:child_process";
export async function openChrome(W = 390, H = 844) {
  const PORT = 9400 + Math.floor(Math.random() * 400);
  const profile = `${process.env.TMPDIR || "/tmp"}/hl-cdp-${PORT}`;
  const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", [
    "--headless=new", `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check",
    "--hide-scrollbars", "--mute-audio", "--autoplay-policy=no-user-gesture-required", "--force-color-profile=srgb", `--window-size=${W},${H}`, "about:blank",
  ], { stdio: "ignore" });
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
  let wsUrl = "";
  for (let i = 0; i < 100 && !wsUrl; i++) {
    try { const l = (await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json()) as any[]; const p = l.find((t) => t.type === "page"); if (p) wsUrl = p.webSocketDebuggerUrl; } catch {}
    if (!wsUrl) await sleep(100);
  }
  const ws = new WebSocket(wsUrl);
  await new Promise((r) => (ws.onopen = r));
  let seq = 0; const pending = new Map<number, (m: any) => void>(); const logs: string[] = [];
  ws.onmessage = (e) => {
    const m = JSON.parse(String(e.data));
    if (m.id && pending.has(m.id)) { pending.get(m.id)!(m); pending.delete(m.id); return; }
    if (m.method === "Runtime.consoleAPICalled") logs.push(`console.${m.params.type}: ` + m.params.args.map((a: any) => a.value ?? a.description).join(" "));
    if (m.method === "Runtime.exceptionThrown") logs.push("EXCEPTION: " + JSON.stringify(m.params.exceptionDetails).slice(0, 500));
    if (m.method === "Log.entryAdded") logs.push(`log.${m.params.entry.level}: ${m.params.entry.text} ${m.params.entry.url || ""}`);
  };
  const send = (method: string, params: any = {}) => new Promise<any>((res, rej) => { const id = ++seq; pending.set(id, (m) => (m.error ? rej(new Error(method + ": " + JSON.stringify(m.error))) : res(m.result))); ws.send(JSON.stringify({ id, method, params })); });
  const evalJS = async (expr: string) => { const r = await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) throw new Error("eval: " + JSON.stringify(r.exceptionDetails).slice(0, 400)); return r.result?.value; };
  await send("Page.enable"); await send("Runtime.enable"); await send("Log.enable");
  return {
    send, evalJS, logs, sleep,
    async view(w: number, h: number, dpr: number) { await send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: dpr, mobile: w < 700 }); await send("Emulation.setTouchEmulationEnabled", { enabled: w < 700, maxTouchPoints: 5 }); },
    async go(url: string) {
      await send("Page.navigate", { url });
      for (let i = 0; i < 200; i++) { const rs = await evalJS("document.readyState").catch(() => ""); if (rs === "complete") break; await sleep(100); }
    },
    async shot(file: string) { const r = await send("Page.captureScreenshot", { format: "png", fromSurface: true, captureBeyondViewport: false }); await Bun.write(file, Buffer.from(r.data, "base64")); },
    close() { ws.close(); chrome.kill(); },
  };
}
