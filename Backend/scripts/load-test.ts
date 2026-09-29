#!/usr/bin/env bun
// Opens N rooms (one Mac + one phone each) against a running service, exchanges signals and
// reports connect latency, signal round trips and failures. Local example:
//   bun run dev            (in another terminal)
//   bun scripts/load-test.ts --url ws://127.0.0.1:8787/signal --rooms 50 --signals 20 --hold 5
// No entitlement tokens are used, so every room is a free (local-only) room; pass --token to
// register the phones with one entitlement token and exercise relay issuance instead.

const args = new Map<string, string>();
for (let i = 2; i < Bun.argv.length; i += 2) args.set(Bun.argv[i]!.replace(/^--/, ""), Bun.argv[i + 1] ?? "");
const url = args.get("url") ?? "ws://127.0.0.1:8787/signal";
const roomCount = Number(args.get("rooms") ?? 20);
const signalsPerRoom = Number(args.get("signals") ?? 10);
const holdSeconds = Number(args.get("hold") ?? 2);
const staggerMs = Number(args.get("stagger") ?? 10);
const token = args.get("token");

const hex = (bytes = 32) => Array.from(crypto.getRandomValues(new Uint8Array(bytes)), b => b.toString(16).padStart(2, "0")).join("");
const sha256 = async (text: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))), b => b.toString(16).padStart(2, "0")).join("");
const payload = btoa(String.fromCharCode(...new Uint8Array(96).fill(5)));

type Peer = { ws: WebSocket; next: () => Promise<Record<string, unknown>>; send: (v: unknown) => void; closed: Promise<string> };

function peer(): Promise<Peer> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const queue: Record<string, unknown>[] = [];
    const waiters: Array<(v: Record<string, unknown>) => void> = [];
    ws.onmessage = event => { const value = JSON.parse(String(event.data)); const waiter = waiters.shift(); if (waiter) waiter(value); else queue.push(value); };
    const closed = new Promise<string>(done => { ws.onclose = event => done(event.reason); });
    ws.onerror = () => reject(new Error("socket error"));
    ws.onopen = () => resolve({
      ws,
      closed,
      send: value => ws.send(JSON.stringify(value)),
      next: () => queue.length ? Promise.resolve(queue.shift()!) : new Promise((ok, fail) => {
        const timer = setTimeout(() => fail(new Error("timeout")), 10_000);
        waiters.push(value => { clearTimeout(timer); ok(value); });
      }),
    });
  });
}

type Result = { connectMs: number; rtts: number[]; error?: string; codes: string[] };

async function runRoom(): Promise<Result> {
  const result: Result = { connectMs: 0, rtts: [], codes: [] };
  const started = performance.now();
  try {
    const hostToken = hex(), clientToken = hex();
    const room = await sha256(hostToken), clientTokenHash = await sha256(clientToken);
    const host = await peer();
    host.send({ type: "register", version: 1, role: "host", room, token: hostToken, clientTokenHash, features: ["renew.1"] });
    const registered = await host.next();
    if (registered.type !== "registered") throw new Error(`host ${String(registered.code)}`);
    await host.next();
    const client = await peer();
    client.send({ type: "register", version: 1, role: "client", room, token: clientToken, features: token ? ["renew.1", "remote.1"] : ["renew.1"], ...(token ? { entitlement: token } : {}) });
    let message = await client.next();
    while (message.type === "error" && message.code === "entitlement_required") { result.codes.push("entitlement_required"); message = await client.next(); }
    if (message.type !== "registered") throw new Error(`client ${String(message.code)}`);
    await client.next();
    if (token) await host.next();
    await Promise.all([client.next(), host.next()]);
    result.connectMs = performance.now() - started;
    for (let i = 0; i < signalsPerRoom; i++) {
      const t0 = performance.now();
      client.send({ type: "signal", payload });
      const echoed = await host.next();
      if (echoed.type !== "signal") throw new Error(`unexpected ${String(echoed.type)}`);
      host.send({ type: "signal", payload });
      const back = await client.next();
      if (back.type !== "signal") throw new Error(`unexpected ${String(back.type)}`);
      result.rtts.push(performance.now() - t0);
    }
    await Bun.sleep(holdSeconds * 1000);
    client.ws.close(1000, "done");
    host.ws.close(1000, "done");
  } catch (error) {
    result.error = error instanceof Error ? error.message : String(error);
  }
  return result;
}

const percentile = (values: number[], p: number) => {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]!;
};

const runs: Promise<Result>[] = [];
for (let i = 0; i < roomCount; i++) {
  runs.push(runRoom());
  await Bun.sleep(staggerMs);
}
const results = await Promise.all(runs);
const ok = results.filter(result => !result.error);
const errors = new Map<string, number>();
for (const result of results) if (result.error) errors.set(result.error, (errors.get(result.error) ?? 0) + 1);
const rtts = ok.flatMap(result => result.rtts);
console.log(JSON.stringify({
  url,
  rooms: roomCount,
  succeeded: ok.length,
  failed: results.length - ok.length,
  connectMs: { p50: percentile(ok.map(r => r.connectMs), 0.5).toFixed(1), p95: percentile(ok.map(r => r.connectMs), 0.95).toFixed(1) },
  signalRoundTripMs: { count: rtts.length, p50: percentile(rtts, 0.5).toFixed(2), p95: percentile(rtts, 0.95).toFixed(2), max: percentile(rtts, 1).toFixed(2) },
  entitlementRequiredNotices: results.reduce((sum, r) => sum + r.codes.length, 0),
  errors: Object.fromEntries(errors),
}, null, 2));
process.exit(results.length === ok.length ? 0 : 1);
