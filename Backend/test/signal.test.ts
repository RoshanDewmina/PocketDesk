import { evictDurableObject } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { mintEntitlementToken } from "../src/entitlement/token";
import type { RoomDO } from "../src/room";
import { randomHex } from "../src/util";
import { parseChain, signCompactJws, transactionPayload, type TestChain } from "./helpers/apple-chain";
import { connectClient, connectHost, open, pairing, payload64, postJson, registerMessage, sleep, testEnv } from "./helpers/client";
import { installTurnMock, type TurnMock } from "./helpers/turn-mock";

let chain: TestChain;
let turn: TurnMock;
const now = Date.now();
let ipCounter = 60;
const freshIp = () => ({ "cf-connecting-ip": `198.51.100.${ipCounter++ % 250}` });
const rooms = () => testEnv.ROOM as unknown as DurableObjectNamespace<RoomDO>;
const snapshot = (room: string) => rooms().get(rooms().idFromName(room)).snapshot();

async function entitlementToken(overrides: Record<string, unknown> = {}, deviceId = randomHex()): Promise<string> {
  const signedTransaction = await signCompactJws(transactionPayload({ originalTransactionId: `sig-${randomHex(6)}`, ...overrides }, now), chain);
  const body = (await (await postJson("/v1/entitlements/verify", { signedTransaction, deviceId }, freshIp())).json()) as Record<string, unknown>;
  if (body.entitled !== true) throw new Error(`not entitled: ${JSON.stringify(body)}`);
  return body.entitlementToken as string;
}

beforeAll(() => {
  chain = parseChain(testEnv.TEST_APPLE_CHAIN);
  turn = installTurnMock();
});

describe("signaling parity with the Bun service", () => {
  it("authenticated opaque exchange and duplicate admission safety", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    const client = await connectClient(p);
    expect((await client.next()).online).toBe(true);
    expect((await host.next()).online).toBe(true);
    const payload = payload64(7);
    client.send({ type: "signal", payload });
    expect((await host.next()).payload).toBe(payload);
    const duplicate = await open();
    duplicate.send(registerMessage(p, "client"));
    expect((await duplicate.next()).code).toBe("already_connected");
    host.send({ type: "signal", payload });
    expect((await client.next()).payload).toBe(payload);
    const duplicateHost = await open();
    duplicateHost.send(registerMessage(p, "host"));
    expect((await duplicateHost.next()).code).toBe("already_connected");
    client.send({ type: "signal", payload });
    expect((await host.next()).payload).toBe(payload);
  });

  it("wrong client token cannot join", async () => {
    const p = await pairing();
    await connectHost(p);
    const c = await open();
    c.send({ ...registerMessage(p, "client"), token: "c".repeat(64) });
    expect(await c.next()).toEqual({ type: "error", code: "host_unavailable_or_unauthorized" });
    expect((await c.closed).reason).toBe("host_unavailable_or_unauthorized");
  });

  it("phone-before-host is terminal on that socket but a fresh retry can join", async () => {
    const p = await pairing();
    const early = await open();
    early.send(registerMessage(p, "client"));
    expect((await early.next()).code).toBe("host_unavailable_or_unauthorized");
    await early.closed;
    const host = await connectHost(p);
    const retry = await connectClient(p);
    expect(retry.registered.type).toBe("registered");
    expect(retry.ice.type).toBe("ice");
    expect((await retry.next()).online).toBe(true);
    expect((await host.next()).online).toBe(true);
  });

  it("host identity and version are checked", async () => {
    const p = await pairing();
    const h = await open();
    h.send({ ...registerMessage(p, "host"), token: "d".repeat(64) });
    expect((await h.next()).code).toBe("unauthorized");
    const c = await open();
    c.send({ ...registerMessage(p, "client"), version: 2 });
    expect((await c.next()).code).toBe("invalid_registration");
    const noHash = await open();
    noHash.send({ type: "register", version: 1, role: "host", room: p.room, token: p.hostToken });
    expect((await noHash.next()).code).toBe("unauthorized");
  });

  it("unregistered signals, malformed JSON and binary frames fail closed", async () => {
    const c = await open();
    c.send({ type: "signal", payload: "a".repeat(64) });
    expect((await c.next()).type).toBe("error");
    const d = await open();
    d.sendRaw("{");
    expect((await d.next()).code).toBe("invalid_message");
    const e = await open();
    e.ws.send(new Uint8Array(16));
    expect((await e.next()).code).toBe("invalid_message");
    await e.closed;
  });

  it("host disconnect closes the client and clears the room", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    const client = await connectClient(p);
    await client.next(); await host.next();
    host.close();
    expect((await client.closed).reason).toBe("host_disconnected");
    await sleep(20);
    expect(await snapshot(p.room)).toMatchObject({ hostOnline: false, clientOnline: false, entitled: false, liveCredentials: 0 });
    const again = await connectHost(p);
    expect(again.registered.type).toBe("registered");
  });

  it("client disconnect keeps the host registered and tells it", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    const client = await connectClient(p);
    await client.next(); await host.next();
    client.close();
    expect(await host.next()).toEqual({ type: "peer", online: false });
    const back = await connectClient(p);
    expect((await back.next()).online).toBe(true);
    expect((await host.next()).online).toBe(true);
  });

  it("payload limits and shapes reject oversized or malformed signals", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    host.send({ type: "signal", payload: "a".repeat(190 * 1024) });
    expect((await host.next()).code).toBe("invalid_message");
    const p2 = await pairing();
    const short = await connectHost(p2);
    short.send({ type: "signal", payload: "abc" });
    expect((await short.next()).code).toBe("invalid_message");
    const p3 = await pairing();
    const lonely = await connectHost(p3);
    lonely.send({ type: "signal", payload: payload64(1) });
    expect(await lonely.next()).toEqual({ type: "error", code: "peer_unavailable" });
    lonely.send({ type: "signal", payload: payload64(2) });
    expect(await lonely.next()).toEqual({ type: "error", code: "peer_unavailable" });
  });

  it("message rate has a concrete bounded failure", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    const client = await connectClient(p);
    await client.next(); await host.next();
    for (let i = 0; i < 101; i++) client.send({ type: "signal", payload: payload64(3) });
    let last: Record<string, unknown> | undefined;
    for (;;) {
      const message = await client.next();
      if (message.type === "error") { last = message; break; }
    }
    expect(last?.code).toBe("rate_limit");
    expect((await client.closed).reason).toBe("rate_limit");
  });

  it("old apps receive byte-compatible messages and no relay", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    expect(host.registered).toEqual({ type: "registered", role: "host" });
    expect(host.ice).toEqual({ type: "ice", servers: [] });
    const client = await connectClient(p);
    expect(client.pre).toEqual([]);
    expect(client.registered).toEqual({ type: "registered", role: "client" });
    expect(client.ice).toEqual({ type: "ice", servers: [] });
    expect(await client.next()).toEqual({ type: "peer", online: true });
    expect(await host.next()).toEqual({ type: "peer", online: true });
  });
});

describe("entitlement gate (remote.1)", () => {
  it("a phone that asks for remote access without a token is told and continues locally", async () => {
    const p = await pairing();
    const host = await connectHost(p, { features: ["remote.1", "renew.1"] });
    expect(host.registered).toMatchObject({ type: "registered", role: "host", access: "local" });
    const client = await connectClient(p, { features: ["remote.1"] });
    expect(client.pre).toEqual([{ type: "error", code: "entitlement_required" }]);
    expect(client.registered).toEqual({ type: "registered", role: "client", access: "local" });
    expect(client.ice).toEqual({ type: "ice", servers: [] });
    expect((await client.next()).online).toBe(true);
    expect((await host.next()).online).toBe(true);
    expect(turn.generateCalls).toBe(0);
  });

  it("an entitled phone gets relay for itself and the Mac, and credentials are revoked when it leaves", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p);
    const client = await connectClient(p, { features: ["remote.1"], entitlement: token });
    expect(client.pre).toEqual([]);
    expect(client.registered).toEqual({ type: "registered", role: "client", access: "remote" });
    const clientTurn = (client.ice.servers as Array<{ urls: string[]; username?: string }>).find(server => server.username);
    expect(clientTurn?.urls[0]).toContain("turn:");
    expect(clientTurn?.username).toMatch(/^user-\d$/);
    const hostIce = await host.next();
    expect(hostIce.type).toBe("ice");
    const hostTurn = (hostIce.servers as Array<{ username?: string }>).find(server => server.username);
    expect(hostTurn?.username).toMatch(/^user-\d$/);
    expect(hostTurn?.username).not.toBe(clientTurn?.username);
    expect(await host.next()).toEqual({ type: "peer", online: true });
    expect(await client.next()).toEqual({ type: "peer", online: true });
    expect(turn.generateCalls).toBe(2);
    expect(await snapshot(p.room)).toMatchObject({ entitled: true, liveCredentials: 2 });
    expect(JSON.stringify(await snapshot(p.room))).not.toContain("user-");

    client.close();
    expect(await host.next()).toEqual({ type: "peer", online: false });
    await sleep(50);
    expect([...turn.revoked].sort()).toEqual([...turn.issued].sort());
    expect(await snapshot(p.room)).toMatchObject({ entitled: false, liveCredentials: 0 });
  });

  it("an expired, forged or revoked token yields local access only", async () => {
    turn.reset();
    const p = await pairing();
    const host = await connectHost(p);
    const expired = await mintEntitlementToken(testEnv.ENTITLEMENT_TOKEN_KEY, { v: 1, d: randomHex(), s: randomHex(), x: Math.floor(now / 1000) - 10, n: "P", e: "test" });
    const a = await connectClient(p, { entitlement: expired });
    expect(a.pre).toEqual([{ type: "error", code: "entitlement_required" }]);
    expect(a.registered.access).toBe("local");
    a.close();
    await host.next(); await host.next();

    const forged = await mintEntitlementToken("not-the-key-0123456789abcdef0123456789abcdef", { v: 1, d: randomHex(), s: randomHex(), x: Math.floor(now / 1000) + 600, n: "P", e: "test" });
    const b = await connectClient(p, { entitlement: forged });
    expect(b.pre).toEqual([{ type: "error", code: "entitlement_required" }]);
    b.close();
    await host.next(); await host.next();

    const token = await entitlementToken();
    await testEnv.DB.prepare("UPDATE entitlements SET status = 'revoked', revoked_at = ?1").bind(now).run();
    const c = await connectClient(p, { entitlement: token });
    expect(c.pre).toEqual([{ type: "error", code: "entitlement_required" }]);
    expect(c.ice.servers).toEqual([]);
    expect(turn.generateCalls).toBe(0);
  });

  it("a token stops working the moment its device is unlinked", async () => {
    turn.reset();
    const deviceId = randomHex();
    const token = await entitlementToken({}, deviceId);
    const forget = await postJson("/v1/entitlements/forget", { deviceId, entitlementToken: token }, freshIp());
    expect(forget.status).toBe(204);
    const p = await pairing();
    await connectHost(p);
    const client = await connectClient(p, { features: ["remote.1"], entitlement: token });
    expect(client.pre).toEqual([{ type: "error", code: "entitlement_required" }]);
    expect(client.ice.servers).toEqual([]);
    expect(turn.generateCalls).toBe(0);
  });

  it("one device is live in one room at a time: joining a second room ends the first room's relay", async () => {
    turn.reset();
    const token = await entitlementToken();
    const first = await pairing();
    const hostA = await connectHost(first);
    const clientA = await connectClient(first, { features: ["remote.1"], entitlement: token });
    expect(clientA.registered.access).toBe("remote");
    await hostA.next(); await hostA.next(); await clientA.next();

    const second = await pairing();
    const hostB = await connectHost(second);
    const clientB = await connectClient(second, { features: ["remote.1"], entitlement: token });
    expect(clientB.registered.access).toBe("remote");
    const [aHost, aClient] = await Promise.all([hostA.closed, clientA.closed]);
    expect(aHost.reason).toBe("entitlement_revoked");
    expect(aClient.reason).toBe("entitlement_revoked");
    expect(await snapshot(first.room)).toMatchObject({ hostOnline: false, clientOnline: false, entitled: false });
    expect(await snapshot(second.room)).toMatchObject({ hostOnline: true, clientOnline: true, entitled: true });
    await sleep(50);
    expect(turn.revoked.length).toBe(2);
    hostB.close(); clientB.close();
  });

  it("a kicked socket cannot disturb the peer that replaces it", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p);
    const first = await connectClient(p, { features: ["remote.1"], entitlement: token });
    await host.next(); await host.next(); await first.next();
    first.send({ type: "nonsense" });
    expect((await first.next()).code).toBe("invalid_message");
    expect(await host.next()).toEqual({ type: "peer", online: false });
    expect((await host.next()).type).toBe("ice");
    const replacement = await connectClient(p, { features: ["remote.1"], entitlement: token });
    expect(replacement.registered.access).toBe("remote");
    await first.closed;
    await sleep(30);
    expect((await host.next()).type).toBe("ice");
    expect(await host.next()).toEqual({ type: "peer", online: true });
    expect(await snapshot(p.room)).toMatchObject({ hostOnline: true, clientOnline: true, entitled: true, liveCredentials: 2 });
    replacement.send({ type: "signal", payload: payload64(5) });
    expect((await host.next()).payload).toBe(payload64(5));
  });

  it("a relay provider failure fails the entitled registration closed and leaves the host registered", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p);
    turn.failNext(2);
    const client = await open();
    client.send(registerMessage(p, "client", { features: ["remote.1"], entitlement: token }));
    expect(await client.next()).toEqual({ type: "error", code: "relay_unavailable" });
    expect((await client.closed).reason).toBe("relay_unavailable");
    expect(host.messages).toEqual([]);
    const retry = await connectClient(p, { features: ["remote.1"], entitlement: token });
    expect(retry.registered.access).toBe("remote");
  });

  it("a room survives hibernation: peers, entitlement and credentials are restored from attachments and storage", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p, { features: ["renew.1"] });
    const client = await connectClient(p, { features: ["renew.1", "remote.1"], entitlement: token });
    await host.next(); await host.next(); await client.next();

    await evictDurableObject(rooms().get(rooms().idFromName(p.room)));

    client.send({ type: "signal", payload: payload64(4) });
    expect((await host.next()).payload).toBe(payload64(4));
    host.send({ type: "renew" });
    expect((await host.next()).type).toBe("renewed");
    expect(await snapshot(p.room)).toMatchObject({ hostOnline: true, clientOnline: true, entitled: true, liveCredentials: 2 });
    const intruder = await open();
    intruder.send(registerMessage(p, "client"));
    expect((await intruder.next()).code).toBe("already_connected");

    client.close();
    expect(await host.next()).toEqual({ type: "peer", online: false });
    await sleep(50);
    expect([...turn.revoked].sort()).toEqual([...turn.issued].sort());
  });

  it("the entitlement token is never echoed and rooms never leak identifiers in readiness", async () => {
    const token = await entitlementToken();
    const p = await pairing();
    await connectHost(p);
    const client = await connectClient(p, { features: ["remote.1"], entitlement: token });
    const everything = JSON.stringify([client.registered, client.ice, ...client.messages]);
    expect(everything).not.toContain(token);
    expect(everything).not.toContain(p.room);
  });
});
