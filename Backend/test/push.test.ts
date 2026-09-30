import { beforeAll, afterEach, describe, expect, it, vi } from "vitest";
import { forgetPushRoom, handlePushEvent, handlePushPreferences, handlePushRegister, handlePushRemove, handlePushReport, purgePushRetention } from "../src/push";
import { purgeRetention } from "../src/entitlement/store";
import { randomHex, sha256Hex } from "../src/util";
import { connectHost, pairing, postJson, sleep, testEnv, type Pairing } from "./helpers/client";
import { installTurnMock } from "./helpers/turn-mock";

beforeAll(() => { installTurnMock(); });
afterEach(() => { vi.unstubAllGlobals(); });

const req = (path: string, body: unknown) => new Request(`https://farside.test/v1/push/${path}`, {
  method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
});
const registration = (deviceToken = randomHex(), enabled = true) => ({
  deviceToken, environment: "sandbox", alertsEnabled: enabled, timeSensitive: false,
  showAgentName: false, locale: "en_CA", appBuild: "20260929.1", osMajor: 18, updatedAt: Math.floor(Date.now() / 1000),
});
const register = (env: Env, p: Pairing, value: unknown) =>
  handlePushRegister(req("register", { room: p.room, token: p.clientToken, registration: value }), env);
const event = (env: Env, p: Pairing, id = `h_${randomHex(6)}`, overrides: Record<string, unknown> = {}) =>
  handlePushEvent(req("event", { room: p.room, hostToken: p.hostToken, id, kind: "claude_code",
    event: "needs_user", sessionHash: "aabbccdd", raisedAt: Math.floor(Date.now() / 1000), ...overrides }), env);

async function configuredEnv(): Promise<Env> {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const bytes = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keys.privateKey) as ArrayBuffer);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...bytes))}\n-----END PRIVATE KEY-----`;
  return Object.assign({ ...testEnv }, {
    APNS_TEAM_ID: "ABCDEFGHIJ", APNS_KEY_ID: "ABCDEFGHIJ", APNS_PRIVATE_KEY: pem,
  });
}

async function livePair(): Promise<Pairing> {
  const p = await pairing();
  await connectHost(p);
  await sleep(30); // room enrollment is scheduled after host registration
  return p;
}

describe("pairing-scoped generic APNs alerts", () => {
  it("rejects unknown rooms, wrong proofs, and wrong APNs environment before storing an address", async () => {
    const env = await configuredEnv();
    const unknown = await pairing();
    expect((await register(env, unknown, registration())).status).toBe(401);
    const p = await livePair();
    const wrong = await handlePushRegister(req("register", {
      room: p.room, token: randomHex(), registration: registration(),
    }), env);
    expect(wrong.status).toBe(401);
    expect((await event(env, p, undefined, { hostToken: randomHex() })).status).toBe(401);
    expect((await register(env, p, { ...registration(), environment: "production" })).status).toBe(400);
    expect((await register(env, p, { ...registration(), deviceToken: "bad" })).status).toBe(400);
    expect(await testEnv.DB.prepare("SELECT room FROM push_registrations WHERE room=?1").bind(p.room).first()).toBeNull();
  });

  it("fails closed without APNs credentials or phone opt-in", async () => {
    const p = await livePair();
    const missing = Object.assign({ ...testEnv }, { APNS_TEAM_ID: "", APNS_KEY_ID: "", APNS_PRIVATE_KEY: "" });
    expect((await register(missing, p, registration())).status).toBe(503);
    const env = await configuredEnv();
    await testEnv.DB.prepare(`INSERT INTO activity_registrations
      (room,route_epoch,activity_id,push_token,environment,updated_at)
      VALUES (?1,?2,'active-session','ab','sandbox',?3)`)
      .bind(p.room, "a".repeat(32), Date.now()).run();
    expect((await register(env, p, registration(randomHex(), false))).status).toBe(200);
    expect((await event(env, p)).status).toBe(409);
    expect(await testEnv.DB.prepare("SELECT activity_id AS id FROM activity_registrations WHERE room=?1")
      .bind(p.room).first<{ id: string }>()).toEqual({ id: "active-session" });
  });

  it("sends only generic fields, reports actions, and holds duplicates", async () => {
    const env = await configuredEnv();
    const p = await livePair();
    // An older phone may still ask for the agent's name; the push stays generic anyway.
    expect((await register(env, p, { ...registration(), showAgentName: true })).status).toBe(200);
    const sent: { url: string; body: string; headers: Headers }[] = [];
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      sent.push({ url, body: String(init.body), headers: new Headers(init.headers) });
      return new Response(null, { status: 200 });
    });
    const id = `h_${randomHex(6)}`;
    const answer = await event(env, p, id);
    expect(answer.status).toBe(202);
    expect(await answer.json()).toEqual({ state: "accepted" });
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toContain("api.sandbox.push.apple.com");
    const payload = JSON.parse(sent[0]!.body) as Record<string, unknown>;
    expect(payload).toMatchObject({ hid: id,
      pairing: await sha256Hex(`${p.room}:${await sha256Hex(p.clientToken)}`),
      aps: { alert: { "title-loc-key": "AGENT_NEEDS_YOU_TITLE", "loc-key": "AGENT_NEEDS_YOU_BODY" }, category: "AGENT_HELP" } });
    expect((payload.aps as { alert: Record<string, unknown> }).alert).not.toHaveProperty("title-loc-args");
    expect(sent[0]!.body).not.toMatch(/claude|codex|cursor/i);
    expect(sent[0]!.body).not.toContain(p.hostToken);
    expect(sent[0]!.body).not.toContain(p.clientToken);
    expect(sent[0]!.headers.get("apns-topic")).toBe(testEnv.APP_BUNDLE_ID);
    const duplicate = await event(env, p);
    expect(await duplicate.json()).toEqual({ state: "held" });
    expect(sent).toHaveLength(1);
    const report = await handlePushReport(req("report", {
      room: p.room, token: p.clientToken, helpRequestID: id, action: "snoozed",
      at: Math.floor(Date.now() / 1000),
    }), env);
    expect(report.status).toBe(200);
    expect(await testEnv.DB.prepare("SELECT action FROM push_reports WHERE room=?1 AND id=?2")
      .bind(p.room, id).first<{ action: string }>()).toEqual({ action: "snoozed" });
    await purgePushRetention(testEnv.DB, Date.now() + 16 * 60_000);
    expect(await testEnv.DB.prepare("SELECT id FROM push_events WHERE room=?1 AND id=?2")
      .bind(p.room, id).first()).toBeNull();
    expect(await testEnv.DB.prepare("SELECT id FROM push_reports WHERE room=?1 AND id=?2")
      .bind(p.room, id).first()).toBeNull();
  });

  it("purges a report orphaned when an APNs failure removes its event", async () => {
    const env = await configuredEnv();
    const p = await livePair();
    expect((await register(env, p, registration())).status).toBe(200);
    vi.stubGlobal("fetch", async () => new Response(null, { status: 200 }));
    const id = `h_${randomHex(6)}`;
    expect((await event(env, p, id)).status).toBe(202);
    expect((await handlePushReport(req("report", {
      room: p.room, token: p.clientToken, helpRequestID: id, action: "opened",
      at: Math.floor(Date.now() / 1000),
    }), env)).status).toBe(200);
    await testEnv.DB.prepare("DELETE FROM push_events WHERE room=?1 AND id=?2").bind(p.room, id).run();
    await purgePushRetention(testEnv.DB, Date.now());
    expect(await testEnv.DB.prepare("SELECT id FROM push_reports WHERE room=?1 AND id=?2")
      .bind(p.room, id).first()).toBeNull();
  });

  it("a delayed APNs 410 and a delayed old-token removal cannot erase a rotated registration", async () => {
    const env = await configuredEnv();
    const p = await livePair();
    const oldToken = randomHex();
    const newToken = randomHex();
    expect((await register(env, p, registration(oldToken))).status).toBe(200);
    vi.stubGlobal("fetch", async () => {
      expect((await register(env, p, registration(newToken))).status).toBe(200);
      return new Response(null, { status: 410 });
    });
    expect((await event(env, p)).status).toBe(503);
    expect((await handlePushRemove(req("remove", {
      room: p.room, token: p.clientToken, deviceToken: oldToken,
    }), env)).status).toBe(204);
    expect(await testEnv.DB.prepare("SELECT device_token AS token FROM push_registrations WHERE room=?1")
      .bind(p.room).first<{ token: string }>()).toEqual({ token: newToken });
    await forgetPushRoom(testEnv.DB, p.room);
    expect(await testEnv.DB.prepare("SELECT room FROM push_registrations WHERE room=?1").bind(p.room).first()).toBeNull();
  });

  it("allows offline opt-out but rejects the old pairing after a host re-pairs", async () => {
    const env = await configuredEnv();
    const p = await pairing();
    const host = await connectHost(p);
    await sleep(30);
    expect((await register(env, p, registration())).status).toBe(200);
    host.close();
    await host.closed;
    const address = await testEnv.DB.prepare("SELECT device_token AS token FROM push_registrations WHERE room=?1")
      .bind(p.room).first<{ token: string }>();
    expect(address).not.toBeNull();
    expect((await handlePushRemove(req("remove", {
      room: p.room, token: p.clientToken, deviceToken: address!.token,
    }), env)).status).toBe(204);
    expect((await register(env, p, registration())).status).toBe(200);
    const newerToken = randomHex();
    const replacement = { ...p, clientToken: newerToken, clientTokenHash: await sha256Hex(newerToken) };
    await connectHost(replacement);
    await sleep(30);
    expect(await testEnv.DB.prepare("SELECT room FROM push_registrations WHERE room=?1").bind(p.room).first()).toBeNull();
    expect((await register(env, p, registration())).status).toBe(401);
    expect((await register(env, replacement, registration())).status).toBe(200);
  });

  it("removes an old phone's registration if its pairing rotates during the D1 write", async () => {
    const env = await configuredEnv();
    const p = await livePair();
    const oldToken = randomHex();
    let checks = 0;
    const gate = { authenticatePush: async () => ++checks === 1 };
    Object.assign(env, { ROOM: { idFromName: (room: string) => room, get: () => gate } });
    expect((await register(env, p, registration(oldToken))).status).toBe(401);
    expect(await testEnv.DB.prepare("SELECT device_token FROM push_registrations WHERE room=?1")
      .bind(p.room).first()).toBeNull();
  });

  it("never dispatches to an in-flight old pairing and preserves a new pair using the same APNs token", async () => {
    const env = await configuredEnv();
    const p = await livePair();
    const deviceToken = randomHex();
    const oldHash = await sha256Hex(p.clientToken);
    const newHash = await sha256Hex(randomHex());
    let enterSecondCheck!: () => void;
    let releaseSecondCheck!: () => void;
    const secondCheckEntered = new Promise<void>(resolve => { enterSecondCheck = resolve; });
    const secondCheckReleased = new Promise<void>(resolve => { releaseSecondCheck = resolve; });
    let checks = 0;
    const gate = {
      authenticatePush: async () => {
        if (++checks === 1) return true;
        enterSecondCheck();
        await secondCheckReleased;
        return false;
      },
      authenticatePushHash: async () => false,
    };
    Object.assign(env, { ROOM: { idFromName: (room: string) => room, get: () => gate } });
    const pending = register(env, p, registration(deviceToken));
    await secondCheckEntered;
    expect(await testEnv.DB.prepare("SELECT pairing_hash AS pairingHash FROM push_registrations WHERE room=?1")
      .bind(p.room).first()).toEqual({ pairingHash: oldHash });
    const apns = vi.fn(async () => new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", apns);
    expect((await event(env, p)).status).toBe(503);
    expect(apns).not.toHaveBeenCalled();
    // The replacement phone can retain the same opaque APNs address. The old request's
    // post-auth cleanup must compare the pairing hash as well as token and version.
    await testEnv.DB.prepare("UPDATE push_registrations SET pairing_hash=?2 WHERE room=?1")
      .bind(p.room, newHash).run();
    releaseSecondCheck();
    expect((await pending).status).toBe(401);
    expect(await testEnv.DB.prepare("SELECT pairing_hash AS pairingHash FROM push_registrations WHERE room=?1")
      .bind(p.room).first()).toEqual({ pairingHash: newHash });
  });

  it("a stale phone's cleanup cannot erase a newer push address", async () => {
    const env = await configuredEnv();
    const p = await livePair();
    const oldToken = randomHex();
    const newToken = randomHex();
    let checks = 0;
    const gate = { authenticatePush: async () => {
      checks += 1;
      if (checks === 2) {
        await testEnv.DB.prepare("UPDATE push_registrations SET device_token=?2,version=version+1 WHERE room=?1")
          .bind(p.room, newToken).run();
      }
      return checks === 1;
    } };
    Object.assign(env, { ROOM: { idFromName: (room: string) => room, get: () => gate } });
    expect((await register(env, p, registration(oldToken))).status).toBe(401);
    expect(await testEnv.DB.prepare("SELECT device_token AS token FROM push_registrations WHERE room=?1")
      .bind(p.room).first()).toEqual({ token: newToken });
  });

  it("disables alerts without a fresh APNs token while retaining the ActivityKit end address", async () => {
    const env = await configuredEnv();
    const p = await livePair();
    expect((await register(env, p, registration())).status).toBe(200);
    await testEnv.DB.prepare(`INSERT INTO activity_registrations
      (room,route_epoch,activity_id,push_token,environment,updated_at)
      VALUES (?1,?2,'held-activity','ab','sandbox',?3)`)
      .bind(p.room, randomHex(16), Date.now()).run();
    const disable = (token: string) => handlePushPreferences(req("preferences", {
      room: p.room, token, alertsEnabled: false,
    }), env);
    expect((await disable(randomHex())).status).toBe(401);
    expect(await testEnv.DB.prepare("SELECT room FROM push_registrations WHERE room=?1")
      .bind(p.room).first()).not.toBeNull();
    expect((await disable(p.clientToken)).status).toBe(200);
    expect((await postJson("/v1/push/preferences", {
      room: p.room, token: p.clientToken, alertsEnabled: false,
    })).status).toBe(200);
    expect(await testEnv.DB.prepare("SELECT room FROM push_registrations WHERE room=?1")
      .bind(p.room).first()).toBeNull();
    expect(await testEnv.DB.prepare("SELECT activity_id FROM activity_registrations WHERE room=?1")
      .bind(p.room).first()).toEqual({ activity_id: "held-activity" });
    expect((await handlePushPreferences(req("preferences", {
      room: p.room, token: p.clientToken, alertsEnabled: true,
    }), env)).status).toBe(400);
  });

  it("bounds APNs registrations by room retention without deleting pending Activity ends or tombstones", async () => {
    const now = Date.now();
    const year = 365 * 24 * 60 * 60_000;
    const freshRoom = randomHex(32);
    const oldAddressRoom = randomHex(32);
    const expiredRoom = randomHex(32);
    const missingRoom = randomHex(32);
    for (const [room, lastSeen] of [[freshRoom, now], [oldAddressRoom, now], [expiredRoom, now - year - 1]] as const) {
      await testEnv.DB.prepare("INSERT INTO rooms (id,first_seen,last_seen,status) VALUES (?1,?2,?3,'active')")
        .bind(room, lastSeen, lastSeen).run();
    }
    for (const [room, updatedAt] of [[freshRoom, now], [oldAddressRoom, now - year - 1],
      [expiredRoom, now], [missingRoom, now]] as const) {
      await testEnv.DB.prepare(`INSERT INTO push_registrations
        (room,pairing_hash,device_token,environment,alerts_enabled,time_sensitive,show_agent_name,locale,app_build,os_major,updated_at)
        VALUES (?1,?2,?3,'sandbox',1,0,0,'en_CA','test',18,?4)`)
        .bind(room, randomHex(), randomHex(), updatedAt).run();
    }
    for (const [room, activityID, nextRetryAt] of [[expiredRoom, "pending-end", now + 60_000],
      [missingRoom, "ended-tombstone", null]] as const) {
      await testEnv.DB.prepare(`INSERT INTO activity_registrations
        (room,route_epoch,activity_id,push_token,environment,updated_at,end_reason,end_at,next_retry_at)
        VALUES (?1,?2,?3,'ab','sandbox',?4,'expired',?4,?5)`)
        .bind(room, randomHex(16), activityID, now, nextRetryAt).run();
    }
    expect((await purgeRetention(testEnv.DB, now)).rooms).toBeGreaterThanOrEqual(1);
    await purgePushRetention(testEnv.DB, now);
    const remaining = await testEnv.DB.prepare("SELECT room FROM push_registrations WHERE room IN (?1,?2,?3,?4)")
      .bind(freshRoom, oldAddressRoom, expiredRoom, missingRoom).all<{ room: string }>();
    expect(remaining.results).toEqual([{ room: freshRoom }]);
    expect(await testEnv.DB.prepare("SELECT activity_id FROM activity_registrations WHERE room IN (?1,?2) ORDER BY activity_id")
      .bind(expiredRoom, missingRoom).all()).toMatchObject({ results: [
        { activity_id: "ended-tombstone" }, { activity_id: "pending-end" },
      ] });
  });
});
