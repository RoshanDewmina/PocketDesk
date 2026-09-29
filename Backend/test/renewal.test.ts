import { runDurableObjectAlarm } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { RoomDO } from "../src/room";
import { randomHex } from "../src/util";
import { parseChain, signCompactJws, transactionPayload, type TestChain } from "./helpers/apple-chain";
import { connectClient, connectHost, open, pairing, postJson, registerMessage, sleep, testEnv } from "./helpers/client";
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
    client.send({ type: "renew" });
    expect((await client.next()).code).toBe("invalid_message");
    host.send({ type: "renew", extra: 1 });
    expect((await host.next()).code).toBe("invalid_message");
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

  it("unauthenticated sockets time out at the room", async () => {
    const p = await pairing();
    await connectHost(p);
    const idle = await open();
    idle.send(registerMessage(p, "client"));
    await idle.next(); await idle.next();
    expect(await runDurableObjectAlarm(stub(p.room))).toBe(true);
    expect(idle.ws.readyState).toBe(WebSocket.OPEN);
  });
});
