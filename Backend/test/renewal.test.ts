import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { RoomDO } from "../src/room";
import { randomHex } from "../src/util";
import { parseChain, signCompactJws, transactionPayload, type TestChain } from "./helpers/apple-chain";
import { connectClient, connectHost, open, pairing, payload64, postJson, registerMessage, sleep, testEnv } from "./helpers/client";
import { installTurnMock, type TurnMock } from "./helpers/turn-mock";

const minute = 60_000;
const renewing = ["renew.1"];
let chain: TestChain;
let turn: TurnMock;
let start: number;
let ipCounter = 90;
const freshIp = () => ({ "cf-connecting-ip": `198.51.100.${ipCounter++ % 250}` });
const rooms = () => testEnv.ROOM as unknown as DurableObjectNamespace<RoomDO>;
const stub = (room: string) => rooms().get(rooms().idFromName(room));

async function advance(ms: number) {
  vi.setSystemTime(Date.now() + ms);
  await sleep(5);
}

async function entitlementToken(): Promise<string> {
  const signedTransaction = await signCompactJws(transactionPayload({ originalTransactionId: `rn-${randomHex(6)}`, expiresDate: Date.now() + 30 * 24 * 60 * minute }, Date.now()), chain);
  const body = (await (await postJson("/v1/entitlements/verify", { signedTransaction, deviceId: randomHex() }, freshIp())).json()) as Record<string, unknown>;
  if (body.entitled !== true) throw new Error(`not entitled: ${JSON.stringify(body)}`);
  return body.entitlementToken as string;
}

beforeAll(() => {
  chain = parseChain(testEnv.TEST_APPLE_CHAIN);
  turn = installTurnMock();
});

beforeEach(() => {
  start = Date.now();
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(start);
});

afterEach(() => {
  vi.useRealTimers();
});

describe("lease and renewal", () => {
  it("offers renewal only to peers that ask, with the Bun service's numbers", async () => {
    const p = await pairing();
    const host = await connectHost(p, { features: renewing });
    expect(host.registered).toEqual({ type: "registered", role: "host", renew: { version: 1, leaseSeconds: 1800, renewAfterSeconds: 900 } });
    const client = await connectClient(p);
    expect(client.registered).toEqual({ type: "registered", role: "client" });
    await client.next(); await host.next();
    client.send({ type: "renew" });
    const refused = await client.next();
    expect(refused, JSON.stringify(refused)).toEqual({ type: "error", code: "invalid_message" });
    expect((await client.closed).reason).toBe("invalid_message");
    expect(await host.next()).toEqual({ type: "peer", online: false });
    host.send({ type: "renew", extra: 1 });
    const malformed = await host.next();
    expect(malformed, JSON.stringify(malformed)).toEqual({ type: "error", code: "invalid_message" });
  });

  it("a room in which nobody renews ends at the lease exactly as before", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    const client = await connectClient(p);
    await client.next(); await host.next();
    await advance(30 * minute - 1000);
    expect(await runDurableObjectAlarm(stub(p.room))).toBe(true);
    expect(host.ws.readyState).toBe(WebSocket.OPEN);
    await advance(2000);
    expect(await runDurableObjectAlarm(stub(p.room))).toBe(true);
    const [hostClose, clientClose] = await Promise.all([host.closed, client.closed]);
    expect(hostClose.reason).toBe("room_lifetime_reached");
    expect(clientClose.reason).toBe("host_disconnected");
  });

  it("renewing peers keep the room past 30, 60 and 120 minutes and it still ends when they stop", async () => {
    const p = await pairing();
    const host = await connectHost(p, { features: renewing });
    const client = await connectClient(p, { features: renewing });
    await client.next(); await host.next();
    for (let elapsed = 0; elapsed < 125 * minute; elapsed += 15 * minute) {
      await advance(15 * minute);
      host.send({ type: "renew" });
      const renewed = await host.next();
      expect(renewed).toMatchObject({ type: "renewed", leaseSeconds: 1800 });
      expect(renewed.servers).toBeUndefined();
      await runDurableObjectAlarm(stub(p.room));
      expect(host.ws.readyState).toBe(WebSocket.OPEN);
      expect(client.ws.readyState).toBe(WebSocket.OPEN);
    }
    await advance(31 * minute);
    await runDurableObjectAlarm(stub(p.room));
    expect((await host.closed).reason).toBe("room_lifetime_reached");
  });

  it("a renewal after the lease ran out is refused; one just before extends from that moment", async () => {
    const p = await pairing();
    const host = await connectHost(p, { features: renewing });
    await advance(30 * minute - 1000);
    host.send({ type: "renew" });
    expect((await host.next()).type).toBe("renewed");
    await advance(29 * minute);
    await runDurableObjectAlarm(stub(p.room));
    expect(host.ws.readyState).toBe(WebSocket.OPEN);

    const p2 = await pairing();
    const late = await connectHost(p2, { features: renewing });
    await advance(30 * minute + 1000);
    late.send({ type: "renew" });
    expect((await late.closed).reason).toBe("room_lifetime_reached");
  });

  it("the phone alone keeps a room alive for a Mac app that does not renew", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    const client = await connectClient(p, { features: renewing });
    await client.next(); await host.next();
    for (let i = 0; i < 8; i++) {
      await advance(15 * minute);
      client.send({ type: "renew" });
      expect((await client.next()).type).toBe("renewed");
      await runDurableObjectAlarm(stub(p.room));
    }
    expect(host.ws.readyState).toBe(WebSocket.OPEN);
    expect(host.messages.every(message => message.type !== "renewed")).toBe(true);
  });

  it("an entitled peer's credentials are refreshed a third of the way through their life and old ones are kept until it leaves", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p, { features: renewing });
    const client = await connectClient(p, { features: [...renewing, "remote.1"], entitlement: token });
    expect(client.registered.renew).toEqual({ version: 1, leaseSeconds: 1800, renewAfterSeconds: 900, credentialSeconds: 3600 });
    await host.next(); await host.next(); await client.next();
    expect(turn.issued).toHaveLength(2);

    await advance(15 * minute);
    client.send({ type: "renew" });
    const early = await client.next();
    expect(early.servers).toBeUndefined();
    expect(early.renewAfterSeconds).toBeLessThanOrEqual(5 * 60 + 1);

    await advance(6 * minute);
    client.send({ type: "renew" });
    const refreshed = await client.next();
    expect(refreshed.credentialSeconds).toBe(3600);
    const username = (refreshed.servers as Array<{ username?: string }>).find(server => server.username)?.username;
    expect(username).toBe("user-3");
    expect(turn.revoked).toEqual([]);
    expect(await stub(p.room).snapshot()).toMatchObject({ liveCredentials: 3 });

    client.close();
    await sleep(50);
    expect([...turn.revoked].sort()).toEqual([...turn.issued].sort());
  });

  it("a lapsed entitlement stops credential refresh but keeps the lease", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p, { features: renewing });
    const client = await connectClient(p, { features: [...renewing, "remote.1"], entitlement: token });
    await host.next(); await host.next(); await client.next();
    await testEnv.DB.prepare("UPDATE entitlements SET status = 'expired', expires_at = ?1").bind(Date.now() - 1).run();
    await advance(21 * minute);
    client.send({ type: "renew" });
    const renewed = await client.next();
    expect(renewed).toMatchObject({ type: "renewed", leaseSeconds: 1800, code: "entitlement_required" });
    expect(renewed.servers).toBeUndefined();
    expect(turn.generateCalls).toBe(2);
    expect(client.ws.readyState).toBe(WebSocket.OPEN);
  });

  it("a D1 lookup outage never issues replacement TURN credentials on renewal", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p, { features: renewing });
    const client = await connectClient(p, { features: [...renewing, "remote.1"], entitlement: token });
    await host.next(); await host.next(); await client.next();
    await advance(21 * minute);
    const originalPrepare = testEnv.DB.prepare.bind(testEnv.DB);
    const failing = vi.spyOn(testEnv.DB, "prepare").mockImplementation(query => {
      if (query.includes("SELECT e.*, d.last_room")) throw new Error("D1 unavailable");
      return originalPrepare(query);
    });
    try {
      client.send({ type: "renew" });
      const renewed = await client.next();
      expect(renewed).toMatchObject({ type: "renewed", code: "relay_unavailable" });
      expect(renewed.servers).toBeUndefined();
      expect(turn.generateCalls).toBe(2);
      expect(client.ws.readyState).toBe(WebSocket.OPEN);
      expect(host.ws.readyState).toBe(WebSocket.OPEN);
    } finally {
      failing.mockRestore();
    }
  });

  it("a provider outage on refresh keeps the room and reports relay_unavailable", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p, { features: renewing });
    const client = await connectClient(p, { features: [...renewing, "remote.1"], entitlement: token });
    await host.next(); await host.next(); await client.next();
    turn.failNext(1);
    await advance(21 * minute);
    client.send({ type: "renew" });
    const failed = await client.next();
    expect(failed).toMatchObject({ type: "renewed", code: "relay_unavailable", renewAfterSeconds: 30 });
    client.send({ type: "renew" });
    const recovered = await client.next();
    expect(recovered.credentialSeconds).toBe(3600);
    expect(client.ws.readyState).toBe(WebSocket.OPEN);
  });

  it("a revocation the provider did not confirm is retried from the alarm until it succeeds", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p, { features: renewing });
    const client = await connectClient(p, { features: [...renewing, "remote.1"], entitlement: token });
    await host.next(); await host.next(); await client.next();
    turn.failRevokeNext(2);
    client.close();
    expect(await host.next()).toEqual({ type: "peer", online: false });
    await sleep(50);
    expect(turn.revoked).toEqual([]);
    expect(await stub(p.room).snapshot()).toMatchObject({ liveCredentials: 0, pendingRevocations: 2 });
    await advance(61_000);
    expect(await runDurableObjectAlarm(stub(p.room))).toBe(true);
    await sleep(50);
    expect([...turn.revoked].sort()).toEqual([...turn.issued].sort());
    expect(await stub(p.room).snapshot()).toMatchObject({ pendingRevocations: 0 });
  });

  it("room forget retains failed TURN revocations through its data wipe and retries them", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p);
    const client = await connectClient(p, { features: ["remote.1"], entitlement: token });
    await host.next(); await host.next(); await client.next();
    turn.failRevokeNext(2);
    expect((await postJson("/v1/rooms/forget", { room: p.room, token: p.hostToken }, freshIp())).status).toBe(204);
    expect((await host.closed).reason).toBe("room_forgotten");
    expect((await client.closed).reason).toBe("room_forgotten");
    await sleep(50);
    expect(await stub(p.room).snapshot()).toMatchObject({
      hostOnline: false, clientOnline: false, entitled: false, liveCredentials: 0, pendingRevocations: 2,
    });
    expect(turn.revoked).toEqual([]);
    await advance(61_000);
    expect(await runDurableObjectAlarm(stub(p.room))).toBe(true);
    await sleep(50);
    expect([...turn.revoked].sort()).toEqual([...turn.issued].sort());
    expect(await stub(p.room).snapshot()).toMatchObject({ pendingRevocations: 0 });
  });

  it("a 404 from the revoke endpoint right after issuance is retried with backoff until it is confirmed", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p, { features: renewing });
    const client = await connectClient(p, { features: [...renewing, "remote.1"], entitlement: token });
    await host.next(); await host.next(); await client.next();
    expect(turn.issued).toHaveLength(2);

    turn.notFoundRevokeNext(2);
    client.close();
    expect(await host.next()).toEqual({ type: "peer", online: false });
    await sleep(50);
    expect(turn.revokeCalls).toBe(2);
    expect(turn.revoked).toEqual([]);
    expect(await stub(p.room).snapshot()).toMatchObject({ liveCredentials: 0, pendingRevocations: 2 });

    // Backoff for a first retry is 1.5–2.5 s; nothing is due before it.
    await advance(1000);
    await runDurableObjectAlarm(stub(p.room));
    await sleep(50);
    expect(turn.revokeCalls).toBe(2);

    await advance(2000);
    expect(await runDurableObjectAlarm(stub(p.room))).toBe(true);
    await sleep(50);
    expect(turn.revokeCalls).toBe(4);
    expect([...turn.revoked].sort()).toEqual([...turn.issued].sort());
    expect(await stub(p.room).snapshot()).toMatchObject({ pendingRevocations: 0 });
  });

  it("a 404 for a credential older than the propagation window counts as revoked and is not retried", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p, { features: renewing });
    const client = await connectClient(p, { features: [...renewing, "remote.1"], entitlement: token });
    await host.next(); await host.next(); await client.next();

    await advance(31_000);
    turn.notFoundRevokeNext(2);
    client.close();
    expect(await host.next()).toEqual({ type: "peer", online: false });
    await sleep(50);
    expect(turn.revokeCalls).toBe(2);
    expect(turn.revoked).toEqual([]);
    expect(await stub(p.room).snapshot()).toMatchObject({ liveCredentials: 0, pendingRevocations: 0 });

    await advance(2 * minute);
    await runDurableObjectAlarm(stub(p.room));
    await sleep(50);
    expect(turn.revokeCalls).toBe(2);
  });

  it("a live entitled room re-checks the subscription and ends when it was revoked meanwhile", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p, { features: renewing });
    const client = await connectClient(p, { features: [...renewing, "remote.1"], entitlement: token });
    await host.next(); await host.next(); await client.next();
    await testEnv.DB.prepare("UPDATE entitlements SET status = 'revoked', revoked_at = ?1").bind(Date.now()).run();
    await advance(4 * minute);
    await runDurableObjectAlarm(stub(p.room));
    expect(client.ws.readyState).toBe(WebSocket.OPEN);
    await advance(2 * minute);
    await runDurableObjectAlarm(stub(p.room));
    expect((await host.closed).reason).toBe("entitlement_revoked");
    expect((await client.closed).reason).toBe("entitlement_revoked");
    await sleep(50);
    expect([...turn.revoked].sort()).toEqual([...turn.issued].sort());
  });

  it("a socket that reaches the room and never registers times out there; peers are untouched", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    const response = await stub(p.room).fetch("https://room.internal/connect", { headers: { upgrade: "websocket" } });
    const direct = response.webSocket!;
    direct.accept();
    const messages: Record<string, unknown>[] = [];
    direct.addEventListener("message", event => messages.push(JSON.parse(String(event.data)) as Record<string, unknown>));
    const closed = new Promise<string>(resolve => direct.addEventListener("close", event => resolve(event.reason)));
    await advance(6000);
    expect(await runDurableObjectAlarm(stub(p.room))).toBe(true);
    expect(await closed).toBe("authentication_timeout");
    expect(messages).toEqual([{ type: "error", code: "authentication_timeout" }]);
    expect(host.ws.readyState).toBe(WebSocket.OPEN);
    const late = await open();
    late.send(registerMessage(p, "client"));
    expect((await late.next()).type).toBe("registered");
  });
});

describe("NW24: keepalive and stale peer replacement", () => {
  it("a quiet phone socket is replaced by the same phone re-registering; a recent one is not", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    const first = await connectClient(p);
    await first.next(); await host.next();
    const tooSoon = await open();
    tooSoon.send(registerMessage(p, "client"));
    expect((await tooSoon.next()).code).toBe("already_connected");

    await advance(11_000);
    const wrong = await open();
    wrong.send({ ...registerMessage(p, "client"), token: "c".repeat(64) });
    expect((await wrong.next()).code).toBe("host_unavailable_or_unauthorized");
    expect(first.ws.readyState).toBe(WebSocket.OPEN);
    const second = await connectClient(p);
    expect((await first.closed).reason).toBe("replaced");
    expect(await host.next()).toEqual({ type: "peer", online: false });
    expect(await host.next()).toEqual({ type: "peer", online: true });
    expect(await second.next()).toEqual({ type: "peer", online: true });
    const again = await open();
    again.send(registerMessage(p, "client"));
    expect((await again.next()).code).toBe("already_connected");
    second.send({ type: "signal", payload: payload64(3) });
    expect((await host.next()).payload).toBe(payload64(3));
  });

  it("a Mac socket is replaced only after it has been quiet; its phone is told to reconnect", async () => {
    const p = await pairing();
    const host = await connectHost(p, { features: renewing });
    const client = await connectClient(p);
    await client.next(); await host.next();
    await advance(8000);
    host.send({ type: "renew" });
    expect((await host.next()).type).toBe("renewed");
    await advance(8000);
    const tooSoon = await open();
    tooSoon.send(registerMessage(p, "host"));
    expect((await tooSoon.next()).code).toBe("already_connected");

    await advance(3000);
    const replacement = await connectHost(p);
    expect(replacement.registered.role).toBe("host");
    expect((await host.closed).reason).toBe("replaced");
    expect((await client.closed).reason).toBe("host_disconnected");
    const rejoined = await connectClient(p);
    expect(await rejoined.next()).toEqual({ type: "peer", online: true });
  });

  it("the keepalive repeats each peer's current ice, including servers refreshed by a renewal", async () => {
    turn.reset();
    const token = await entitlementToken();
    const p = await pairing();
    const host = await connectHost(p, { features: renewing });
    const client = await connectClient(p, { features: [...renewing, "remote.1"], entitlement: token });
    const hostIce = await host.next();
    expect(hostIce.type).toBe("ice");
    await host.next(); await client.next();
    await runInDurableObject(stub(p.room), (instance: RoomDO) => {
      const room = instance as unknown as { config: Record<string, unknown> };
      room.config = { ...room.config, keepaliveMs: 50_000 };
    });

    await advance(51_000);
    await runDurableObjectAlarm(stub(p.room));
    expect(await host.next()).toEqual(hostIce);
    expect(await client.next()).toEqual(client.ice);

    await advance(21 * minute);
    client.send({ type: "renew" });
    const refreshed = await client.next();
    expect(refreshed.servers).toBeDefined();
    expect(refreshed.servers).not.toEqual(client.ice.servers);
    await advance(51_000);
    await runDurableObjectAlarm(stub(p.room));
    expect(await client.next()).toEqual({ type: "ice", servers: refreshed.servers });
    expect(await host.next()).toEqual(hostIce);
  });
});
