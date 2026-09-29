import { runDurableObjectAlarm } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";
import type { RoomDO } from "../src/room";
import { isPublicEnvironment, loadConfig } from "../src/config";
import { connectClient, connectHost, pairing, sleep, testEnv } from "./helpers/client";

const rooms = () => testEnv.ROOM as unknown as DurableObjectNamespace<RoomDO>;

describe("route.1 server policy", () => {
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
});
