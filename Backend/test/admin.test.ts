import { SELF } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { randomHex } from "../src/util";
import { adminHeaders, connectClient, connectHost, open, pairing, postJson, registerMessage, sleep, testEnv } from "./helpers/client";
import { installTurnMock } from "./helpers/turn-mock";

beforeAll(() => { installTurnMock(); });

describe("health, readiness and operator controls", () => {
  it("/health says nothing about configuration", async () => {
    const response = await SELF.fetch("https://farside.test/health");
    expect(response.status).toBe(200);
    const text = await response.text();
    expect(JSON.parse(text)).toEqual({ status: "ok", protocol: 1 });
    expect(text).not.toContain("k".repeat(32));
  });

  it("/ready and /v1/admin need the admin bearer and never contain identifiers", async () => {
    expect((await SELF.fetch("https://farside.test/ready")).status).toBe(404);
    expect((await SELF.fetch("https://farside.test/ready", { headers: { authorization: "Bearer nope" } })).status).toBe(404);
    const p = await pairing();
    await connectHost(p);
    const response = await SELF.fetch("https://farside.test/ready", { headers: adminHeaders() });
    expect(response.status).toBe(200);
    const text = await response.text();
    const body = JSON.parse(text) as Record<string, unknown>;
    expect(body.status).toBe("ready");
    expect(body.relay).toMatchObject({ provider: "cloudflare", policy: "all" });
    expect((body.counts as Record<string, number>).roomsSeen30d).toBeGreaterThanOrEqual(1);
    expect(text).not.toContain(p.room);
    expect(text).not.toContain(testEnv.ADMIN_TOKEN);
    expect(text).not.toContain("t".repeat(64));
  });

  it("a host registration enrolls the room automatically and records it", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    expect(host.registered.type).toBe("registered");
    await sleep(30);
    const row = await testEnv.DB.prepare("SELECT status, registrations FROM rooms WHERE id = ?1").bind(p.room).first<{ status: string; registrations: number }>();
    expect(row).toEqual({ status: "active", registrations: 1 });
  });

  it("blocking a room ends both peers, refuses re-registration, and unblocking restores it", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    const client = await connectClient(p);
    await client.next(); await host.next();
    const blocked = await postJson(`/v1/admin/rooms/${p.room}/block`, {}, adminHeaders());
    expect(blocked.status).toBe(200);
    const [hostClose, clientClose] = await Promise.all([host.closed, client.closed]);
    expect(hostClose.reason).toBe("room_not_approved");
    expect(clientClose.reason).toBe("room_not_approved");
    const again = await open();
    again.send(registerMessage(p, "host"));
    expect(await again.next()).toEqual({ type: "error", code: "room_not_approved" });
    const status = await (await SELF.fetch(`https://farside.test/v1/admin/rooms/${p.room}/status`, { headers: adminHeaders() })).json();
    expect(status).toMatchObject({ blocked: true, hostOnline: false });
    expect((await postJson(`/v1/admin/rooms/${p.room}/unblock`, {}, adminHeaders())).status).toBe(200);
    const restored = await connectHost(p);
    expect(restored.registered.type).toBe("registered");
    expect((await postJson(`/v1/admin/rooms/${"z".repeat(64)}/block`, {}, adminHeaders())).status).toBe(404);
  });

  it("a block recorded before the room object exists is honoured on first registration", async () => {
    const p = await pairing();
    await testEnv.DB.prepare("INSERT INTO rooms (id, first_seen, last_seen, status, registrations) VALUES (?1, 1, 1, 'blocked', 0)").bind(p.room).run();
    const host = await open();
    host.send(registerMessage(p, "host"));
    expect(await host.next()).toEqual({ type: "error", code: "room_not_approved" });
  });

  it("forget requires the host token and wipes the room", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    const client = await connectClient(p);
    await client.next(); await host.next();
    await sleep(30);
    expect((await postJson("/v1/rooms/forget", { room: p.room, token: randomHex() })).status).toBe(401);
    expect((await postJson("/v1/rooms/forget", { room: p.room, token: "nope" })).status).toBe(400);
    const forgotten = await postJson("/v1/rooms/forget", { room: p.room, token: p.hostToken });
    expect(forgotten.status).toBe(204);
    expect((await host.closed).reason).toBe("room_forgotten");
    expect((await client.closed).reason).toBe("room_forgotten");
    expect(await testEnv.DB.prepare("SELECT id FROM rooms WHERE id = ?1").bind(p.room).first()).toBeNull();
    const back = await connectHost(p);
    expect(back.registered.type).toBe("registered");
  });

  it("forget cannot lift an operator block", async () => {
    const p = await pairing();
    await connectHost(p);
    expect((await postJson(`/v1/admin/rooms/${p.room}/block`, {}, adminHeaders())).status).toBe(200);
    const forgotten = await postJson("/v1/rooms/forget", { room: p.room, token: p.hostToken });
    expect(forgotten.status).toBe(403);
    const again = await open();
    again.send(registerMessage(p, "host"));
    expect(await again.next()).toEqual({ type: "error", code: "room_not_approved" });
    expect((await testEnv.DB.prepare("SELECT status FROM rooms WHERE id = ?1").bind(p.room).first<{ status: string }>())?.status).toBe("blocked");
  });

  it("the test-notification endpoint reports when the App Store Server API key is absent", async () => {
    const response = await postJson("/v1/admin/appstore/test-notification", {}, adminHeaders());
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "apple_server_api_not_configured" });
  });
});
