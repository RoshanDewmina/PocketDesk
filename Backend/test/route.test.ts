import { runDurableObjectAlarm } from "cloudflare:test";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { unentitledRelayPass, type RoomDO } from "../src/room";
import { isPublicEnvironment, loadConfig } from "../src/config";
import { randomHex } from "../src/util";
import { parseChain, signCompactJws, transactionPayload, type TestChain } from "./helpers/apple-chain";
import { connectClient, connectHost, pairing, postJson, sleep, testEnv } from "./helpers/client";
import { installTurnMock } from "./helpers/turn-mock";

const rooms = () => testEnv.ROOM as unknown as DurableObjectNamespace<RoomDO>;
let chain: TestChain;
beforeAll(() => {
  chain = parseChain(testEnv.TEST_APPLE_CHAIN);
  installTurnMock();
});

async function paidToken(): Promise<string> {
  const now = Date.now();
  const signedTransaction = await signCompactJws(transactionPayload({
    originalTransactionId: `route-${randomHex(6)}`, expiresDate: now + 30 * 24 * 60 * 60_000,
  }, now), chain);
  const response = await postJson("/v1/entitlements/verify", { signedTransaction, deviceId: randomHex() },
    { "cf-connecting-ip": `198.51.100.${Math.floor(Math.random() * 200) + 1}` });
  const body = await response.json() as { entitled?: boolean; entitlementToken?: string };
  if (!body.entitled || !body.entitlementToken) throw new Error(`paid fixture failed: ${response.status}`);
  return body.entitlementToken;
}

describe("route.1 server policy", () => {
  it("never gives a Couch registration (no remote.1, no token) the developer relay pass", () => {
    const room = "b".repeat(64);
    const config = { allowUnentitledRelay: false, devRelayRooms: new Set([room]) };
    expect(unentitledRelayPass(config, room, true)).toBe(true);
    expect(unentitledRelayPass(config, room, false)).toBe(false);
    expect(unentitledRelayPass(config, "c".repeat(64), true)).toBe(false);
    expect(unentitledRelayPass(config, undefined, true)).toBe(false);
    expect(unentitledRelayPass({ allowUnentitledRelay: true, devRelayRooms: new Set() }, room, false)).toBe(true);
  });

  it("requires route policy and refuses free relay on both public deployments", () => {
    expect(isPublicEnvironment("staging")).toBe(true);
    expect(isPublicEnvironment("production")).toBe(true);
    expect(isPublicEnvironment("dev")).toBe(false);
    expect(isPublicEnvironment("test")).toBe(false);
    const staging = new Proxy(testEnv, {
      get(target, property) {
        if (property === "ENVIRONMENT_NAME") return "staging";
        if (property === "ALLOW_UNENTITLED_RELAY") return "1";
        return Reflect.get(target, property);
      },
    });
    expect(() => loadConfig(staging)).toThrow("ALLOW_UNENTITLED_RELAY is refused on public deployments");
  });

  it("accepts a staging developer pass for exact rooms only and refuses it in production", () => {
    const withEnv = (name: string, rooms: string) => new Proxy(testEnv, {
      get(target, property) {
        if (property === "ENVIRONMENT_NAME") return name;
        if (property === "DEV_RELAY_ROOMS") return rooms;
        return Reflect.get(target, property);
      },
    });
    const room = "a".repeat(64);
    expect(loadConfig(withEnv("staging", room)).devRelayRooms.has(room)).toBe(true);
    expect(loadConfig(withEnv("staging", "")).devRelayRooms.size).toBe(0);
    expect(() => loadConfig(withEnv("production", room))).toThrow("DEV_RELAY_ROOMS is refused in production");
    expect(() => loadConfig(withEnv("staging", "not-a-room"))).toThrow("DEV_RELAY_ROOMS invalid");
  });

  it("sends one matching, expiring policy to both peers before admitting signaling", async () => {
    const p = await pairing();
    const host = await connectHost(p, { features: ["route.1", "renew.1"] });
    const phone = await connectClient(p, { features: ["route.1", "renew.1"] });
    expect(host.ice).toEqual({ type: "ice", servers: [] });
    expect(phone.ice).toEqual({ type: "ice", servers: [] });
    const [hostRoute, phoneRoute] = await Promise.all([host.next(), phone.next()]);
    expect(hostRoute).toEqual(phoneRoute);
    expect(hostRoute).toMatchObject({ type: "route", version: 1, room: p.room,
      revision: 1, access: "local" });
    expect(hostRoute.epoch).toMatch(/^[0-9a-f]{32}$/);
    expect(Number(hostRoute.expiresAt)).toBeGreaterThan(Date.now());
    expect(Number(hostRoute.expiresAt)).toBeLessThanOrEqual(Date.now() + 30 * 60_000);
    expect(await host.next()).toEqual({ type: "peer", online: true });
    expect(await phone.next()).toEqual({ type: "peer", online: true });

    host.send({ type: "renew" });
    const [hostNext, phoneNext] = await Promise.all([host.next(), phone.next()]);
    expect(hostNext).toMatchObject({ type: "route", epoch: hostRoute.epoch, revision: 2, access: "local" });
    expect(phoneNext).toEqual(hostNext);
    expect((await host.next()).type).toBe("renewed");
    phone.close();
    expect(await host.next()).toEqual({ type: "peer", online: false });
  });

  it("rotates the session epoch when another phone joins the same registered host", async () => {
    const p = await pairing();
    const host = await connectHost(p, { features: ["route.1"] });
    const firstPhone = await connectClient(p, { features: ["route.1"] });
    const firstRoute = await host.next();
    expect(await firstPhone.next()).toEqual(firstRoute);
    await host.next(); await firstPhone.next();

    firstPhone.close();
    expect(await host.next()).toEqual({ type: "peer", online: false });
    const secondPhone = await connectClient(p, { features: ["route.1"] });
    const secondRoute = await host.next();
    expect(await secondPhone.next()).toEqual(secondRoute);
    expect(secondRoute).toMatchObject({ type: "route", revision: 1, room: p.room });
    expect(secondRoute.epoch).toMatch(/^[0-9a-f]{32}$/);
    expect(secondRoute.epoch).not.toBe(firstRoute.epoch);
    expect(await host.next()).toEqual({ type: "peer", online: true });
    expect(await secondPhone.next()).toEqual({ type: "peer", online: true });
  });

  it("rejects a peer-originated route policy frame", async () => {
    const p = await pairing();
    const host = await connectHost(p, { features: ["route.1"] });
    const phone = await connectClient(p, { features: ["route.1"] });
    await host.next(); await phone.next(); await host.next(); await phone.next();
    phone.send({ type: "route", version: 1, room: p.room, epoch: "a".repeat(32),
      revision: 99, access: "remote", expiresAt: Date.now() + 60_000 });
    expect(await phone.next()).toEqual({ type: "error", code: "invalid_message" });
    expect((await phone.closed).reason).toBe("invalid_message");
    expect(await host.next()).toEqual({ type: "peer", online: false });
  });

  it("ends both peers when a policy deadline passes without renewal", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    try {
      const p = await pairing();
      const host = await connectHost(p, { features: ["route.1"] });
      const phone = await connectClient(p, { features: ["route.1"] });
      const route = await host.next(); await phone.next(); await host.next(); await phone.next();
      vi.setSystemTime(Number(route.expiresAt) + 1);
      await sleep(5);
      expect(await runDurableObjectAlarm(rooms().get(rooms().idFromName(p.room)))).toBe(true);
      expect((await host.closed).reason).toBe("route_expired");
      expect((await phone.closed).reason).toBe("route_expired");
    } finally {
      vi.useRealTimers();
    }
  });

  it("ends a paid route when the second refresh lookup becomes unavailable", async () => {
    const token = await paidToken();
    const p = await pairing();
    const host = await connectHost(p, { features: ["route.1", "renew.1"] });
    const phone = await connectClient(p, { features: ["route.1", "renew.1", "remote.1"], entitlement: token });
    expect((await host.next()).type).toBe("ice");
    expect(await host.next()).toMatchObject({ type: "route", access: "remote" });
    expect(await phone.next()).toMatchObject({ type: "route", access: "remote" });
    await host.next(); await phone.next();

    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(Date.now() + 21 * 60_000);
    const originalPrepare = testEnv.DB.prepare.bind(testEnv.DB);
    let entitlementReads = 0;
    const lookup = vi.spyOn(testEnv.DB, "prepare").mockImplementation(query => {
      if (query.includes("SELECT e.*, d.last_room") && ++entitlementReads === 2) {
        throw new Error("D1 unavailable on refresh");
      }
      return originalPrepare(query);
    });
    try {
      phone.send({ type: "renew" });
      expect((await host.closed).reason).toBe("entitlement_unavailable");
      expect((await phone.closed).reason).toBe("entitlement_unavailable");
      expect(entitlementReads).toBeGreaterThanOrEqual(2);
    } finally {
      lookup.mockRestore();
      vi.useRealTimers();
    }
  });
});
