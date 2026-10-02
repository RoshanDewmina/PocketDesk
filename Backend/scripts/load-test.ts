#!/usr/bin/env bun
// Opens rooms against a running service, exchanges signals and reports latency/failures.
// Local: bun run dev (in another terminal), then bun scripts/load-test.ts --rooms 50
// Public service: add --token or FARSIDE_LOAD_ENTITLEMENT_TOKEN for one paid room at a time.
// The load itself is bounded; URLs, credentials, and tokens are never printed.

import { clientFeatures, loadConcurrency, parseBoundedInteger, resolveEntitlementTokens, safeWebSocketUrl, validRoomRegistration } from "./load-test-helpers";

const args = new Map<string, string>();
for (let i = 2; i < Bun.argv.length; i += 2) args.set(Bun.argv[i]!.replace(/^--/, ""), Bun.argv[i + 1] ?? "");
const url = args.get("url") ?? "ws://127.0.0.1:8787/signal";
const roomCount = parseBoundedInteger(args.get("rooms"), 20, 1, 250);
const signalsPerRoom = parseBoundedInteger(args.get("signals"), 10, 1, 1000);
const holdSeconds = parseBoundedInteger(args.get("hold"), 2, 0, 60);
const staggerMs = parseBoundedInteger(args.get("stagger"), 10, 0, 5000);
const requestedConcurrency = parseBoundedInteger(args.get("concurrency"), 20, 1, 20);
const entitlementTokens = resolveEntitlementTokens(roomCount,
  args.get("tokens") ?? Bun.env.FARSIDE_LOAD_ENTITLEMENT_TOKENS,
  args.get("token") ?? Bun.env.FARSIDE_LOAD_ENTITLEMENT_TOKEN);
const hasEntitlement = entitlementTokens.some(Boolean);
const concurrency = loadConcurrency(roomCount, requestedConcurrency, hasEntitlement);
const localTarget = /^ws:\/\/(127\.0\.0\.1|localhost|\[::1\])(?::|\/)/.test(url);
const spoofAddresses = (args.get("spoof-ip") ?? (localTarget ? "1" : "0")) === "1";
if (!safeWebSocketUrl(url)) throw new Error("invalid websocket URL");

let roomIndex = 0;
const hex = (bytes = 32) => Array.from(crypto.getRandomValues(new Uint8Array(bytes)), b => b.toString(16).padStart(2, "0")).join("");
const sha256 = async (value: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))), b => b.toString(16).padStart(2, "0")).join("");
const payload = btoa(String.fromCharCode(...new Uint8Array(96).fill(5)));

type Peer = { ws: WebSocket; next: () => Promise<Record<string, unknown>>; send: (v: unknown) => void; closed: Promise<void> };

function peer(address: string): Promise<Peer> {
  return new Promise((resolve, reject) => {
    const ws = spoofAddresses
      ? new WebSocket(url, { headers: { "cf-connecting-ip": address } } as unknown as string[])
      : new WebSocket(url);
    const queue: Record<string, unknown>[] = [];
    const waiters: Array<(value: Record<string, unknown>) => void> = [];
    let settled = false;
    const openTimer = setTimeout(() => { ws.close(); reject(new Error("connect_timeout")); }, 10_000);
    const closed = new Promise<void>(done => { ws.onclose = () => done(); });
    ws.onmessage = event => {
      const value = JSON.parse(String(event.data));
      const waiter = waiters.shift();
      if (waiter) waiter(value); else queue.push(value);
    };
    ws.onerror = () => {
      if (!settled) { settled = true; clearTimeout(openTimer); ws.close(); reject(new Error("socket_error")); }
    };
    ws.onopen = () => {
      if (settled) return;
      settled = true;
      clearTimeout(openTimer);
      resolve({
        ws,
        closed,
        send: value => ws.send(JSON.stringify(value)),
        next: () => queue.length ? Promise.resolve(queue.shift()!) : new Promise((ok, fail) => {
          const timer = setTimeout(() => fail(new Error("message_timeout")), 10_000);
          waiters.push(value => { clearTimeout(timer); ok(value); });
        }),
      });
    };
  });
}

async function closePeers(peers: Peer[]): Promise<void> {
  for (const item of peers) {
    try { item.ws.close(1000, "load_test_done"); } catch { /* socket already closed */ }
  }
  await Promise.all(peers.map(item => Promise.race([item.closed, Bun.sleep(2000)])));
}

type Result = { connectMs: number; rtts: number[]; error?: string; codes: string[] };

async function collectUntilOnline(item: Peer): Promise<Record<string, unknown>[]> {
  const messages: Record<string, unknown>[] = [];
  for (let i = 0; i < 12; i++) {
    const message = await item.next();
    messages.push(message);
    if (message.type === "peer" && message.online === true) return messages;
    if (message.type === "error" && message.code !== "entitlement_required") return messages;
  }
  throw new Error("registration_message_limit");
}

async function runRoom(token: string | undefined): Promise<Result> {
  const result: Result = { connectMs: 0, rtts: [], codes: [] };
  const started = performance.now();
  const index = roomIndex++;
  const address = `10.${(index >> 16) & 255}.${(index >> 8) & 255}.${index & 255}`;
  const opened: Peer[] = [];
  try {
    const hostToken = hex(), clientToken = hex();
    const room = await sha256(hostToken), clientTokenHash = await sha256(clientToken);
    const host = await peer(address); opened.push(host);
    host.send({ type: "register", version: 1, role: "host", room, token: hostToken, clientTokenHash, features: ["renew.1", "route.1"] });
    const registered = await host.next();
    if (registered.type !== "registered") throw new Error("host_registration_failed");
    await host.next();
    const client = await peer(address); opened.push(client);
    client.send({
      type: "register", version: 1, role: "client", room, token: clientToken,
      features: clientFeatures(),
      ...(token ? { entitlement: token } : {}),
    });
    const [clientMessages, hostMessages] = await Promise.all([collectUntilOnline(client), collectUntilOnline(host)]);
    result.codes = clientMessages.filter(message => message.type === "error" && message.code === "entitlement_required")
      .map(() => "entitlement_required");
    if (!validRoomRegistration(clientMessages, hostMessages, Boolean(token))) throw new Error("room_access_downgraded_or_registration_failed");
    result.connectMs = performance.now() - started;
    for (let i = 0; i < signalsPerRoom; i++) {
      const t0 = performance.now();
      client.send({ type: "signal", payload });
      if ((await host.next()).type !== "signal") throw new Error("unexpected_signal_response");
      host.send({ type: "signal", payload });
      if ((await client.next()).type !== "signal") throw new Error("unexpected_signal_response");
      result.rtts.push(performance.now() - t0);
    }
    await Bun.sleep(holdSeconds * 1000);
  } catch (error) {
    result.error = error instanceof Error ? error.message : "load_test_failed";
  } finally {
    await closePeers(opened);
  }
  return result;
}

const percentile = (values: number[], p: number) => {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]!;
};

const results: Result[] = [];
for (let offset = 0; offset < roomCount; offset += concurrency) {
  const batch = Array.from({ length: Math.min(concurrency, roomCount - offset) }, (_, index) => runRoom(entitlementTokens[offset + index]));
  results.push(...await Promise.all(batch));
  if (offset + concurrency < roomCount) await Bun.sleep(staggerMs);
}
const ok = results.filter(result => !result.error);
const errors = new Map<string, number>();
for (const result of results) if (result.error) errors.set(result.error, (errors.get(result.error) ?? 0) + 1);
const rtts = ok.flatMap(result => result.rtts);
console.log(JSON.stringify({
  url: safeWebSocketUrl(url),
  spoofedAddresses: spoofAddresses,
  rooms: roomCount,
  concurrency,
  paidMode: hasEntitlement,
  succeeded: ok.length,
  failed: results.length - ok.length,
  connectMs: { p50: percentile(ok.map(r => r.connectMs), 0.5).toFixed(1), p95: percentile(ok.map(r => r.connectMs), 0.95).toFixed(1) },
  signalRoundTripMs: { count: rtts.length, p50: percentile(rtts, 0.5).toFixed(2), p95: percentile(rtts, 0.95).toFixed(2), max: percentile(rtts, 1).toFixed(2) },
  entitlementRequiredNotices: results.reduce((sum, result) => sum + result.codes.length, 0),
  errors: Object.fromEntries(errors),
}, null, 2));
process.exit(results.length === ok.length ? 0 : 1);
