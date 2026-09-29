import { beforeAll, afterEach, describe, expect, it, vi } from "vitest";
import { endRoomActivities, handleActivityRegister, handleActivityRemove, retryPendingActivityEnds } from "../src/activity";
import { forgetPushRoom } from "../src/push";
import { randomHex } from "../src/util";
import { connectClient, connectHost, pairing, sleep, testEnv, type Pairing } from "./helpers/client";
import { installTurnMock } from "./helpers/turn-mock";

beforeAll(() => { installTurnMock(); });
afterEach(() => { vi.unstubAllGlobals(); });

const req = (path: string, body: unknown) => new Request(`https://farside.test/v1/activity/${path}`, {
  method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
});
const epoch = randomHex(16);
const identity = (p: Pairing, changes: Record<string, unknown> = {}) => ({
  room: p.room, token: p.clientToken, routeEpoch: epoch, activityId: "A-Farside-Activity_1",
  pushToken: "ab".repeat(300), environment: "sandbox", ...changes,
});

async function envForEpoch(p: Pairing, expectedEpoch = epoch, configured = true): Promise<Env> {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const bytes = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keys.privateKey) as ArrayBuffer);
  const key = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...bytes))}\n-----END PRIVATE KEY-----`;
  const stub = {
    authenticatePush: async (room: string, token: string) => room === p.room && token === p.clientToken,
    authenticateActivity: async (room: string, token: string, routeEpoch: string) =>
      room === p.room && token === p.clientToken && routeEpoch === expectedEpoch,
  };
  const namespace = { idFromName: (room: string) => room, get: () => stub };
  return Object.assign({ ...testEnv }, {
    ROOM: namespace,
    APNS_TEAM_ID: configured ? "ABCDEFGHIJ" : "",
    APNS_KEY_ID: configured ? "ABCDEFGHIJ" : "",
    APNS_PRIVATE_KEY: configured ? key : "",
  }) as unknown as Env;
}

async function livePair(): Promise<Pairing> {
  const p = await pairing();
  await connectHost(p);
  await sleep(30);
  return p;
}

describe("end-only ActivityKit push", () => {
  it("uses the server-published route.1 epoch and refuses registration after the route ends", async () => {
    const p = await pairing();
    const host = await connectHost(p, { features: ["route.1"] });
    const phone = await connectClient(p, { features: ["route.1"] });
    const route = await phone.next();
    await host.next(); await phone.next(); await host.next();
    await sleep(30);
    const env = Object.assign({ ...await envForEpoch(p) }, { ROOM: testEnv.ROOM }) as Env;
    const current = identity(p, { routeEpoch: route.epoch });
    expect((await handleActivityRegister(req("register", current), env)).status).toBe(200);
    expect((await handleActivityRegister(req("register", identity(p, { routeEpoch: randomHex(16) })), env)).status).toBe(401);
    phone.close();
    await host.next();
    expect((await handleActivityRegister(req("register", current), env)).status).toBe(401);
    host.close();
    await host.closed;
    expect((await handleActivityRemove(req("remove", current), env)).status).toBe(204);
  });

  it("rejects a stale epoch, wrong proof, and malformed opaque token", async () => {
    const p = await livePair();
    const env = await envForEpoch(p);
    expect((await handleActivityRegister(req("register", identity(p, { routeEpoch: randomHex(16) })), env)).status).toBe(401);
    expect((await handleActivityRegister(req("register", identity(p, { token: randomHex() })), env)).status).toBe(401);
    expect((await handleActivityRegister(req("register", identity(p, { pushToken: "abc" })), env)).status).toBe(400);
    expect(await testEnv.DB.prepare("SELECT room FROM activity_registrations WHERE room=?1").bind(p.room).first()).toBeNull();
  });

  it("registers and removes an exact room, epoch, activity, token tuple", async () => {
    const p = await livePair();
    const env = await envForEpoch(p);
    expect((await handleActivityRegister(req("register", identity(p)), env)).status).toBe(200);
    expect((await handleActivityRemove(req("remove", identity(p, { pushToken: "cd".repeat(300) })), env)).status).toBe(204);
    expect(await testEnv.DB.prepare("SELECT room FROM activity_registrations WHERE room=?1").bind(p.room).first()).not.toBeNull();
    expect((await handleActivityRemove(req("remove", identity(p)), env)).status).toBe(204);
    expect((await handleActivityRemove(req("remove", identity(p)), env)).status).toBe(204);
    expect(await testEnv.DB.prepare("SELECT room FROM activity_registrations WHERE room=?1").bind(p.room).first()).toBeNull();
  });

  it("sends only an end state to the ActivityKit topic and immediate dismissal", async () => {
    const p = await livePair();
    const env = await envForEpoch(p);
    expect((await handleActivityRegister(req("register", identity(p)), env)).status).toBe(200);
    const sent: { url: string; headers: Headers; body: string }[] = [];
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      sent.push({ url, headers: new Headers(init.headers), body: String(init.body) });
      return new Response(null, { status: 200 });
    });
    expect(await endRoomActivities(env, p.room, epoch, "macStopped")).toEqual({ accepted: 1, failed: 0, invalidToken: 0 });
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toContain("api.sandbox.push.apple.com");
    expect(sent[0]!.headers.get("apns-push-type")).toBe("liveactivity");
    expect(sent[0]!.headers.get("apns-topic")).toBe(`${testEnv.APP_BUNDLE_ID}.push-type.liveactivity`);
    const aps = (JSON.parse(sent[0]!.body) as { aps: Record<string, unknown> }).aps;
    expect(aps).toMatchObject({ event: "end", "content-state": { phase: "ended", endedReason: "macStopped" } });
    expect(aps["dismissal-date"]).toBeLessThan(aps.timestamp as number);
    expect(sent[0]!.body).not.toContain(p.clientToken);
    expect(sent[0]!.body).not.toContain(p.hostToken);
    expect(await testEnv.DB.prepare("SELECT room FROM activity_registrations WHERE room=?1").bind(p.room).first()).toBeNull();
  });

  it("retains failed ends, and an APNs 410 cannot erase a rotated token", async () => {
    const p = await livePair();
    const env = await envForEpoch(p);
    expect((await handleActivityRegister(req("register", identity(p)), env)).status).toBe(200);
    const missing = Object.assign({ ...env }, { APNS_PRIVATE_KEY: "" });
    expect(await endRoomActivities(missing, p.room, epoch, "timeout")).toEqual({ accepted: 0, failed: 1, invalidToken: 0 });
    expect(await testEnv.DB.prepare("SELECT end_reason AS reason FROM activity_registrations WHERE room=?1")
      .bind(p.room).first<{ reason: string }>()).toEqual({ reason: "timeout" });
    const rotated = "cd".repeat(300);
    vi.stubGlobal("fetch", async () => {
      expect((await handleActivityRegister(req("register", identity(p, { pushToken: rotated })), env)).status).toBe(200);
      return new Response(null, { status: 410 });
    });
    expect(await endRoomActivities(env, p.room, epoch, "timeout")).toEqual({ accepted: 0, failed: 0, invalidToken: 1 });
    expect(await testEnv.DB.prepare("SELECT push_token AS token FROM activity_registrations WHERE room=?1")
      .bind(p.room).first<{ token: string }>()).toEqual({ token: rotated });
    await forgetPushRoom(testEnv.DB, p.room);
    expect(await testEnv.DB.prepare("SELECT room FROM activity_registrations WHERE room=?1").bind(p.room).first()).toBeNull();
  });

  it("retries a failed end after room forget with the original event time", async () => {
    const p = await livePair();
    const env = await envForEpoch(p);
    expect((await handleActivityRegister(req("register", identity(p)), env)).status).toBe(200);
    vi.stubGlobal("fetch", async () => new Response(null, { status: 503 }));
    expect(await endRoomActivities(env, p.room, epoch, "user")).toEqual({ accepted: 0, failed: 1, invalidToken: 0 });
    const pending = await testEnv.DB.prepare(`SELECT end_at AS ended, next_retry_at AS retry
      FROM activity_registrations WHERE room=?1`).bind(p.room).first<{ ended: number; retry: number }>();
    expect(pending).not.toBeNull();
    await forgetPushRoom(testEnv.DB, p.room);
    expect(await testEnv.DB.prepare("SELECT room FROM activity_registrations WHERE room=?1").bind(p.room).first()).not.toBeNull();
    const payloads: Array<{ aps: Record<string, unknown> }> = [];
    vi.stubGlobal("fetch", async (_url: string, init: RequestInit) => {
      payloads.push(JSON.parse(String(init.body)) as { aps: Record<string, unknown> });
      return new Response(null, { status: 200 });
    });
    expect(await retryPendingActivityEnds(env, pending!.retry)).toEqual({
      accepted: 1, failed: 0, invalidToken: 0, expired: 0,
    });
    expect(payloads[0]!.aps.timestamp).toBe(Math.floor(pending!.ended / 1000));
    expect(payloads[0]!.aps["dismissal-date"]).toBe(Math.floor(pending!.ended / 1000) - 1);
    expect(await testEnv.DB.prepare("SELECT room FROM activity_registrations WHERE room=?1").bind(p.room).first()).toBeNull();
  });
});
