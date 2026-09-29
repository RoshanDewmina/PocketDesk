import { roomStatus } from "./entitlement/store";
import { allowStrict } from "./ratelimit";
import { BodyTooLarge, HEX64, base64Decode, base64UrlEncode, isRecord, json, readJsonBody, secureEqual, sha256Hex, utf8 } from "./util";

export type PushEnv = Env & { APNS_TEAM_ID?: string; APNS_KEY_ID?: string; APNS_PRIVATE_KEY?: string };
type Registration = {
  deviceToken: string; environment: "sandbox" | "production"; alertsEnabled: boolean;
  timeSensitive: boolean; showAgentName: boolean; locale: string; appBuild: string; osMajor: number;
};
type SavedRegistration = Registration & { version: number; pairingHash: string };

const HELP_ID = /^h_[a-f0-9]{12}$/;
export const DEVICE_TOKEN = /^(?:[a-f0-9]{2}){1,512}$/;
const SESSION_HASH = /^[a-f0-9]{8,16}$/;
const KINDS = new Set(["claude_code", "codex"]);
const ACTIONS = new Set(["opened", "snoozed", "declined", "dismissed"]);
const EVENT_LIFETIME = 15 * 60 * 1000;

export const configured = (env: PushEnv) => Boolean(
  /^[A-Z0-9]{10}$/.test(env.APNS_TEAM_ID ?? "") &&
  /^[A-Z0-9]{10}$/.test(env.APNS_KEY_ID ?? "") &&
  (env.APNS_PRIVATE_KEY ?? "").includes("-----BEGIN PRIVATE KEY-----"),
);

async function body(request: Request): Promise<Record<string, unknown> | null> {
  try {
    const value = await readJsonBody(request, 4096);
    return isRecord(value) ? value : null;
  } catch (error) {
    if (error instanceof BodyTooLarge) return null;
    throw error;
  }
}

function registration(value: unknown): Registration | null {
  if (!isRecord(value) || typeof value.deviceToken !== "string" || !DEVICE_TOKEN.test(value.deviceToken) ||
      (value.environment !== "sandbox" && value.environment !== "production") ||
      typeof value.alertsEnabled !== "boolean" || typeof value.timeSensitive !== "boolean" ||
      typeof value.showAgentName !== "boolean" || typeof value.locale !== "string" || value.locale.length > 48 ||
      !/^[A-Za-z0-9_-]{2,48}$/.test(value.locale) || typeof value.appBuild !== "string" ||
      !/^[A-Za-z0-9.]{1,32}$/.test(value.appBuild) || !Number.isInteger(value.osMajor) ||
      (value.osMajor as number) < 18 || (value.osMajor as number) > 100) return null;
  return value as Registration;
}

async function activeRoom(env: Env, room: string): Promise<boolean> {
  return (await roomStatus(env.DB, room)) === "active";
}

async function clientAllowed(env: Env, room: string, token: string): Promise<boolean> {
  if (!HEX64.test(room) || !HEX64.test(token) || !(await activeRoom(env, room))) return false;
  const rooms = env.ROOM;
  return rooms.get(rooms.idFromName(room)).authenticatePush(room, token);
}

async function pairingHashCurrent(env: Env, room: string, pairingHash: string): Promise<boolean> {
  if (!(await activeRoom(env, room))) return false;
  const rooms = env.ROOM;
  return rooms.get(rooms.idFromName(room)).authenticatePushHash(room, pairingHash);
}

export function expectedEnvironment(env: Env): "production" | "sandbox" {
  return env.ENVIRONMENT_NAME === "production" ? "production" : "sandbox";
}

export async function handlePushRegister(request: Request, env: Env): Promise<Response> {
  const input = await body(request);
  if (!input || typeof input.room !== "string" || typeof input.token !== "string") return json({ error: "invalid_request" }, 400);
  // No object is created for an unknown or blocked room.
  if (!(await clientAllowed(env, input.room, input.token))) return json({ error: "unauthorized" }, 401);
  const value = registration(input.registration);
  if (!value || value.environment !== expectedEnvironment(env)) return json({ error: "invalid_registration" }, 400);
  if (!configured(env as PushEnv)) return json({ error: "push_unavailable" }, 503);
  if (!(await allowStrict(env.RL_API_DEVICE, `push:${input.room}`, "RL_API_DEVICE")))
    return json({ error: "rate_limited" }, 429, { "retry-after": "60" });
  const pairingHash = await sha256Hex(input.token);
  if (!value.alertsEnabled) {
    await forgetAgentAlertsPairing(env.DB, input.room, pairingHash);
    return json({ state: "removed" }, 200);
  }
  await env.DB.prepare(`INSERT INTO push_registrations
    (room, pairing_hash, device_token, environment, alerts_enabled, time_sensitive, show_agent_name, locale, app_build, os_major, version, updated_at)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 1, ?11)
    ON CONFLICT(room) DO UPDATE SET device_token=excluded.device_token, environment=excluded.environment,
      alerts_enabled=excluded.alerts_enabled, time_sensitive=excluded.time_sensitive,
      show_agent_name=excluded.show_agent_name, locale=excluded.locale, app_build=excluded.app_build,
      os_major=excluded.os_major, pairing_hash=excluded.pairing_hash,
      version=push_registrations.version+1, updated_at=excluded.updated_at`)
    .bind(input.room, pairingHash, value.deviceToken, value.environment, Number(value.alertsEnabled), Number(value.timeSensitive),
      Number(value.showAgentName), value.locale, value.appBuild, value.osMajor, Date.now()).run();
  const saved = await env.DB.prepare("SELECT device_token AS deviceToken, pairing_hash AS pairingHash, version FROM push_registrations WHERE room=?1")
    .bind(input.room).first<{ deviceToken: string; pairingHash: string; version: number }>();
  // A host can replace its phone pairing while this D1 write is in flight. If that happened,
  // remove only the address this request wrote; a newer phone's rotated token must survive.
  if (!(await clientAllowed(env, input.room, input.token))) {
    if (saved?.deviceToken === value.deviceToken && saved.pairingHash === pairingHash) {
      await env.DB.prepare("DELETE FROM push_registrations WHERE room=?1 AND device_token=?2 AND pairing_hash=?3 AND version=?4")
        .bind(input.room, value.deviceToken, pairingHash, saved.version).run();
    }
    return json({ error: "unauthorized" }, 401);
  }
  return json({ state: "registered" }, 200);
}

export async function handlePushRemove(request: Request, env: Env): Promise<Response> {
  const input = await body(request);
  if (!input || typeof input.room !== "string" || typeof input.token !== "string" ||
      typeof input.deviceToken !== "string" || !DEVICE_TOKEN.test(input.deviceToken)) return json({ error: "invalid_request" }, 400);
  if (!(await clientAllowed(env, input.room, input.token))) return json({ error: "unauthorized" }, 401);
  if (!(await allowStrict(env.RL_API_DEVICE, `push:${input.room}`, "RL_API_DEVICE")))
    return json({ error: "rate_limited" }, 429, { "retry-after": "60" });
  // A delayed opt-out for an old APNs token cannot erase a newer rotated registration.
  await env.DB.prepare("DELETE FROM push_registrations WHERE room = ?1 AND device_token = ?2 AND pairing_hash = ?3")
    .bind(input.room, input.deviceToken, await sha256Hex(input.token)).run();
  return new Response(null, { status: 204 });
}

/** A paired phone may disable agent alerts after relaunch even before APNs returns a new token. */
export async function handlePushPreferences(request: Request, env: Env): Promise<Response> {
  const input = await body(request);
  if (!input || typeof input.room !== "string" || typeof input.token !== "string" ||
      input.alertsEnabled !== false) return json({ error: "invalid_request" }, 400);
  if (!(await clientAllowed(env, input.room, input.token))) return json({ error: "unauthorized" }, 401);
  if (!(await allowStrict(env.RL_API_DEVICE, `push:${input.room}`, "RL_API_DEVICE")))
    return json({ error: "rate_limited" }, 429, { "retry-after": "60" });
  await forgetAgentAlertsPairing(env.DB, input.room, await sha256Hex(input.token));
  return json({ state: "removed" }, 200);
}

export async function apnsToken(env: PushEnv): Promise<string> {
  const pem = env.APNS_PRIVATE_KEY!.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const key = await crypto.subtle.importKey("pkcs8", base64Decode(pem) as BufferSource,
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = base64UrlEncode(utf8(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = base64UrlEncode(utf8(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) })));
  const input = `${header}.${claims}`;
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8(input) as BufferSource));
  return `${input}.${base64UrlEncode(signature)}`;
}

function sendAPNs(env: PushEnv, saved: SavedRegistration, input: Record<string, unknown>, bearer: string,
  notificationIdentity: string): Promise<Response> {
  const name = saved.showAgentName ? (input.kind === "claude_code" ? "Claude Code" : "Codex") : "An agent";
  const payload = {
    aps: {
      alert: { "title-loc-key": "AGENT_NEEDS_YOU_TITLE", "title-loc-args": [name], "loc-key": "AGENT_NEEDS_YOU_BODY" },
      category: "AGENT_HELP", "thread-id": `mac-${String(input.room).slice(0, 8)}`,
      "interruption-level": saved.timeSensitive ? "time-sensitive" : "active", sound: "default",
    }, hid: input.id, pairing: notificationIdentity,
  };
  const host = saved.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  return fetch(`https://${host}/3/device/${saved.deviceToken}`, {
    method: "POST",
    headers: { authorization: `bearer ${bearer}`, "apns-push-type": "alert",
      "apns-topic": env.APP_BUNDLE_ID, "apns-priority": "10", "apns-expiration": String(Math.floor(Date.now() / 1000) + 900),
      "apns-collapse-id": `${String(input.room).slice(0, 8)}-${String(input.sessionHash)}`,
      "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
}

/** APNs 200 means accepted by Apple, never proof that a phone displayed it. */
export async function handlePushEvent(request: Request, env: Env): Promise<Response> {
  const input = await body(request);
  if (!input || typeof input.room !== "string" || !HEX64.test(input.room) ||
      typeof input.hostToken !== "string" || !HEX64.test(input.hostToken) ||
      !HELP_ID.test(String(input.id)) || !SESSION_HASH.test(String(input.sessionHash)) ||
      !KINDS.has(String(input.kind)) || input.event !== "needs_user" || !Number.isInteger(input.raisedAt))
    return json({ error: "invalid_request" }, 400);
  // Reject a forged host before touching the object or reading the registry.
  if (!(await secureEqual(await sha256Hex(input.hostToken), input.room))) return json({ error: "unauthorized" }, 401);
  if (!(await activeRoom(env, input.room))) return json({ error: "unknown_room" }, 404);
  const now = Date.now();
  if (Math.abs(now - (input.raisedAt as number) * 1000) > 300_000) return json({ error: "stale_event" }, 400);
  const row = await env.DB.prepare(`SELECT pairing_hash AS pairingHash, device_token AS deviceToken, environment, alerts_enabled AS alertsEnabled,
    time_sensitive AS timeSensitive, show_agent_name AS showAgentName, locale, app_build AS appBuild,
    os_major AS osMajor, version FROM push_registrations WHERE room = ?1`).bind(input.room).first<SavedRegistration>();
  if (!row || !row.alertsEnabled) return json({ error: "not_opted_in" }, 409);
  if (!configured(env as PushEnv)) return json({ error: "push_unavailable" }, 503);
  const admitted = await env.DB.prepare(`INSERT OR IGNORE INTO push_events (room,pairing_hash,id,session_hash,kind,raised_at,expires_at)
    SELECT ?1,?2,?3,?4,?5,?6,?7 WHERE
    (SELECT COUNT(*) FROM push_events WHERE room=?1 AND pairing_hash=?2 AND raised_at>?8) < 6 AND
    NOT EXISTS (SELECT 1 FROM push_events WHERE room=?1 AND pairing_hash=?2 AND session_hash=?4 AND raised_at>?9)`)
    .bind(input.room, row.pairingHash, input.id, input.sessionHash, input.kind, now, now + EVENT_LIFETIME,
      now - 3_600_000, now - 60_000).run();
  if ((admitted.meta.changes ?? 0) === 0) return json({ state: "held" }, 202);
  try {
    // Sign first, then fence the final address against both D1 and the DO pairing immediately
    // before starting APNs fetch. A stale in-flight registration cannot target an old phone.
    const bearer = await apnsToken(env as PushEnv);
    const notificationIdentity = await sha256Hex(`${input.room}:${row.pairingHash}`);
    const current = await env.DB.prepare("SELECT device_token AS deviceToken, pairing_hash AS pairingHash, version FROM push_registrations WHERE room=?1")
      .bind(input.room).first<{ deviceToken: string; pairingHash: string; version: number }>();
    if (current?.version !== row.version || current.deviceToken !== row.deviceToken ||
        current.pairingHash !== row.pairingHash || !(await pairingHashCurrent(env, input.room, row.pairingHash)))
      throw new Error("push_registration_changed");
    const response = await sendAPNs(env as PushEnv, row, input, bearer, notificationIdentity);
    if (response.status === 410) {
      // A delayed APNs reply must not delete a newer registration after token rotation.
      await env.DB.prepare("DELETE FROM push_registrations WHERE room=?1 AND device_token=?2 AND pairing_hash=?3 AND version=?4")
        .bind(input.room, row.deviceToken, row.pairingHash, row.version).run();
    }
    if (response.status !== 200) throw new Error("apns_refused");
    return json({ state: "accepted" }, 202);
  } catch {
    await env.DB.prepare("DELETE FROM push_events WHERE room=?1 AND pairing_hash=?2 AND id=?3")
      .bind(input.room, row.pairingHash, input.id).run();
    return json({ error: "push_unavailable" }, 503);
  }
}

export async function handlePushReport(request: Request, env: Env): Promise<Response> {
  const input = await body(request);
  if (!input || typeof input.room !== "string" || typeof input.token !== "string" ||
      !HELP_ID.test(String(input.helpRequestID)) || !ACTIONS.has(String(input.action)) || !Number.isInteger(input.at))
    return json({ error: "invalid_request" }, 400);
  if (!(await clientAllowed(env, input.room, input.token))) return json({ error: "unauthorized" }, 401);
  const pairingHash = await sha256Hex(input.token);
  const event = await env.DB.prepare("SELECT id FROM push_events WHERE room=?1 AND pairing_hash=?2 AND id=?3 AND expires_at>?4")
    .bind(input.room, pairingHash, input.helpRequestID, Date.now()).first();
  if (!event) return json({ error: "unknown_event" }, 404);
  await env.DB.prepare("INSERT OR IGNORE INTO push_reports (room,pairing_hash,id,action,reported_at) VALUES (?1,?2,?3,?4,?5)")
    .bind(input.room, pairingHash, input.helpRequestID, input.action, Date.now()).run();
  return json({ state: "recorded" }, 200);
}

async function forgetAgentAlertsPairing(db: D1Database, room: string, pairingHash: string): Promise<void> {
  await db.batch([
    db.prepare("DELETE FROM push_registrations WHERE room=?1 AND pairing_hash=?2").bind(room, pairingHash),
    db.prepare("DELETE FROM push_events WHERE room=?1 AND pairing_hash=?2").bind(room, pairingHash),
    db.prepare("DELETE FROM push_reports WHERE room=?1 AND pairing_hash=?2").bind(room, pairingHash),
  ]);
}

export async function forgetPushRoom(db: D1Database, room: string): Promise<void> {
  await db.batch([
    db.prepare("DELETE FROM push_registrations WHERE room=?1").bind(room),
    db.prepare("DELETE FROM push_events WHERE room=?1").bind(room),
    db.prepare("DELETE FROM push_reports WHERE room=?1").bind(room),
    db.prepare("DELETE FROM activity_registrations WHERE room=?1 AND end_reason IS NULL").bind(room),
  ]);
}

export async function purgePushRetention(db: D1Database, now: number): Promise<void> {
  await db.batch([
    db.prepare(`DELETE FROM push_reports WHERE reported_at<=?1 OR NOT EXISTS
      (SELECT 1 FROM push_events e WHERE e.room=push_reports.room AND e.pairing_hash=push_reports.pairing_hash
       AND e.id=push_reports.id AND e.expires_at>?2)`).bind(now - EVENT_LIFETIME, now),
    db.prepare("DELETE FROM push_events WHERE expires_at<=?1").bind(now),
    db.prepare(`DELETE FROM push_registrations WHERE updated_at < ?1 OR NOT EXISTS
      (SELECT 1 FROM rooms WHERE rooms.id=push_registrations.room AND rooms.status='active')`)
      .bind(now - 365 * 24 * 60 * 60_000),
  ]);
}
