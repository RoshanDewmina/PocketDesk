import { SELF } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { randomHex, sha256Hex } from "../../src/util";

export const testEnv = env as unknown as Env & { TEST_APPLE_CHAIN: string; TEST_MIGRATIONS: D1Migration[] };

export type Message = Record<string, unknown> & { type: string };

export type Peer = {
  ws: WebSocket;
  next(timeoutMs?: number): Promise<Message>;
  send(value: unknown): void;
  sendRaw(text: string): void;
  closed: Promise<{ code: number; reason: string }>;
  messages: Message[];
  close(): void;
};

let socketCounter = 0;
/** Each test socket gets its own source address so per-IP limits (30 upgrades/min) only trip in the tests that intend it. */
const nextIp = () => { socketCounter += 1; return `10.${(socketCounter >> 16) & 255}.${(socketCounter >> 8) & 255}.${socketCounter & 255}`; };

export async function open(path = "/signal", headers: Record<string, string> = {}): Promise<Peer> {
  const response = await SELF.fetch(`https://farside.test${path}`, { headers: { upgrade: "websocket", "cf-connecting-ip": nextIp(), ...headers } });
  if (response.status !== 101 || !response.webSocket) throw new Error(`upgrade failed: ${response.status} ${await response.text()}`);
  const ws = response.webSocket;
  ws.accept();
  const messages: Message[] = [];
  const waiters: Array<(value: Message) => void> = [];
  ws.addEventListener("message", event => {
    const value = JSON.parse(String(event.data)) as Message;
    const waiter = waiters.shift();
    if (waiter) waiter(value); else messages.push(value);
  });
  const closed = new Promise<{ code: number; reason: string }>(resolve => {
    ws.addEventListener("close", event => resolve({ code: event.code, reason: event.reason }));
  });
  return {
    ws,
    messages,
    closed,
    next: (timeoutMs = 4000) => messages.length ? Promise.resolve(messages.shift()!) : new Promise<Message>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("message timeout")), timeoutMs);
      waiters.push(value => { clearTimeout(timer); resolve(value); });
    }),
    send: value => ws.send(JSON.stringify(value)),
    sendRaw: text => ws.send(text),
    close: () => { try { ws.close(1000, "test"); } catch { /* closed */ } },
  };
}

export type Pairing = { hostToken: string; clientToken: string; room: string; clientTokenHash: string };

export async function pairing(): Promise<Pairing> {
  const hostToken = randomHex();
  const clientToken = randomHex();
  return { hostToken, clientToken, room: await sha256Hex(hostToken), clientTokenHash: await sha256Hex(clientToken) };
}

export function registerMessage(p: Pairing, role: "host" | "client", extra: Record<string, unknown> = {}): Record<string, unknown> {
  return role === "host"
    ? { type: "register", version: 1, role, room: p.room, token: p.hostToken, clientTokenHash: p.clientTokenHash, ...extra }
    : { type: "register", version: 1, role, room: p.room, token: p.clientToken, ...extra };
}

export async function connectHost(p: Pairing, extra: Record<string, unknown> = {}): Promise<Peer & { registered: Message; ice: Message }> {
  const host = await open();
  host.send(registerMessage(p, "host", extra));
  const registered = await host.next();
  if (registered.type !== "registered") throw new Error(`host not registered: ${JSON.stringify(registered)}`);
  const ice = await host.next();
  return Object.assign(host, { registered, ice });
}

export async function connectClient(p: Pairing, extra: Record<string, unknown> = {}): Promise<Peer & { registered: Message; ice: Message; pre: Message[] }> {
  const client = await open();
  client.send(registerMessage(p, "client", extra));
  const pre: Message[] = [];
  let registered = await client.next();
  while (registered.type === "error" && registered.code === "entitlement_required") {
    pre.push(registered);
    registered = await client.next();
  }
  if (registered.type !== "registered") throw new Error(`client not registered: ${JSON.stringify(registered)}`);
  const ice = await client.next();
  return Object.assign(client, { registered, ice, pre });
}

export const payload64 = (fill = 7) => btoa(String.fromCharCode(...new Uint8Array(64).fill(fill)));

export const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

export async function postJson(path: string, body: unknown, headers: Record<string, string> = {}): Promise<Response> {
  return SELF.fetch(`https://farside.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.7", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

export const adminHeaders = () => ({ authorization: `Bearer ${testEnv.ADMIN_TOKEN}` });
