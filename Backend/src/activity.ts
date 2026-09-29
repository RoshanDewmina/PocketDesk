import { roomStatus } from "./entitlement/store";
import { apnsToken, configured, DEVICE_TOKEN, expectedEnvironment, type PushEnv } from "./push";
import { allowStrict } from "./ratelimit";
import { BodyTooLarge, HEX64, isRecord, json, readJsonBody } from "./util";

const EPOCH = /^[a-f0-9]{32}$/;
const ACTIVITY_ID = /^[A-Za-z0-9_-]{1,128}$/;
const REASONS = new Set(["macStopped", "timeout", "user", "error"]);
const END_RETRY_LIFETIME = 15 * 60_000;
const MAX_END_ATTEMPTS = 8;
const MAX_ACTIVE_ACTIVITIES_PER_EPOCH = 4;
type ActivityRow = {
  room: string; route_epoch: string; activity_id: string; push_token: string;
  environment: "sandbox" | "production"; version: number; end_reason: string | null;
  end_at: number | null; next_retry_at: number | null; attempts: number;
};
type Identity = { room: string; token: string; routeEpoch: string; activityId: string; pushToken: string; environment: string };

async function body(request: Request): Promise<Record<string, unknown> | null> {
  try {
    const value = await readJsonBody(request, 4096);
    return isRecord(value) ? value : null;
  } catch (error) {
    if (error instanceof BodyTooLarge) return null;
    throw error;
  }
}

function identity(value: Record<string, unknown> | null): Identity | null {
  if (!value || typeof value.room !== "string" || !HEX64.test(value.room) ||
      typeof value.token !== "string" || !HEX64.test(value.token) ||
      typeof value.routeEpoch !== "string" || !EPOCH.test(value.routeEpoch) ||
      typeof value.activityId !== "string" || !ACTIVITY_ID.test(value.activityId) ||
      typeof value.pushToken !== "string" || !DEVICE_TOKEN.test(value.pushToken) ||
      (value.environment !== "sandbox" && value.environment !== "production")) return null;
  return value as Identity;
}

async function roomIsActive(env: Env, room: string): Promise<boolean> {
  return (await roomStatus(env.DB, room)) === "active";
}

async function clientAllowed(env: Env, input: Identity, currentEpoch: boolean): Promise<boolean> {
  // D1 is checked before instantiating a DO for an unknown or blocked room.
  if (!(await roomIsActive(env, input.room))) return false;
  const rooms = env.ROOM;
  const stub = rooms.get(rooms.idFromName(input.room));
  return currentEpoch
    ? stub.authenticateActivity(input.room, input.token, input.routeEpoch)
    : stub.authenticatePush(input.room, input.token);
}

export async function handleActivityRegister(request: Request, env: Env): Promise<Response> {
  const input = identity(await body(request));
  if (!input) return json({ error: "invalid_request" }, 400);
  const routeAllowed = await clientAllowed(env, input, true);
  if (!routeAllowed) {
    // A push token may rotate after the route ends. Only the same paired phone may replace the
    // address of an already-ended activity; it cannot create an activity in an old epoch.
    if (!(await clientAllowed(env, input, false))) return json({ error: "unauthorized_or_stale_route" }, 401);
    const terminal = await env.DB.prepare(`SELECT end_reason FROM activity_registrations
      WHERE room=?1 AND route_epoch=?2 AND activity_id=?3`)
      .bind(input.room, input.routeEpoch, input.activityId).first<{ end_reason: string | null }>();
    if (!terminal?.end_reason) return json({ error: "unauthorized_or_stale_route" }, 401);
  }
  if (input.environment !== expectedEnvironment(env)) return json({ error: "invalid_environment" }, 400);
  if (!configured(env as PushEnv)) return json({ error: "activity_push_unavailable" }, 503);
  if (!(await allowStrict(env.RL_API_DEVICE, `activity:${input.room}`, "RL_API_DEVICE")))
    return json({ error: "rate_limited" }, 429, { "retry-after": "60" });
  const now = Date.now();
  if (routeAllowed) {
    const written = await env.DB.prepare(`INSERT INTO activity_registrations
      (room,route_epoch,activity_id,push_token,environment,version,updated_at,end_reason)
      SELECT ?1,?2,?3,?4,?5,1,?6,NULL WHERE
        (SELECT COUNT(*) FROM activity_registrations
         WHERE room=?1 AND route_epoch=?2 AND end_reason IS NULL)<?7
        OR EXISTS (SELECT 1 FROM activity_registrations
                   WHERE room=?1 AND route_epoch=?2 AND activity_id=?3)
      ON CONFLICT(room,route_epoch,activity_id) DO UPDATE SET push_token=excluded.push_token,
        environment=excluded.environment, version=activity_registrations.version+1,
        updated_at=excluded.updated_at,
        next_retry_at=CASE WHEN activity_registrations.end_reason IS NOT NULL
          AND activity_registrations.local_removed=0
          AND activity_registrations.end_at>?8
          AND activity_registrations.push_token<>excluded.push_token THEN excluded.updated_at
          ELSE activity_registrations.next_retry_at END,
        attempts=CASE WHEN activity_registrations.end_reason IS NOT NULL
          AND activity_registrations.local_removed=0
          AND activity_registrations.end_at>?8
          AND activity_registrations.push_token<>excluded.push_token THEN 0
          ELSE activity_registrations.attempts END`)
      .bind(input.room, input.routeEpoch, input.activityId, input.pushToken, input.environment,
        now, MAX_ACTIVE_ACTIVITIES_PER_EPOCH, now - END_RETRY_LIFETIME).run();
    if ((written.meta.changes ?? 0) === 0) return json({ error: "activity_limit" }, 429);
  } else {
    const updated = await env.DB.prepare(`UPDATE activity_registrations SET
      push_token=?4, environment=?5, version=version+1, updated_at=?6,
      next_retry_at=CASE WHEN local_removed=0 AND end_at>?7 AND push_token<>?4 THEN ?6 ELSE next_retry_at END,
      attempts=CASE WHEN local_removed=0 AND end_at>?7 AND push_token<>?4 THEN 0 ELSE attempts END
      WHERE room=?1 AND route_epoch=?2 AND activity_id=?3 AND end_reason IS NOT NULL`)
      .bind(input.room, input.routeEpoch, input.activityId, input.pushToken, input.environment,
        now, now - END_RETRY_LIFETIME).run();
    if ((updated.meta.changes ?? 0) === 0) return json({ error: "unauthorized_or_stale_route" }, 401);
  }
  const row = await env.DB.prepare(`SELECT room,route_epoch,activity_id,push_token,environment,version,
    end_reason,end_at,next_retry_at,attempts FROM activity_registrations
    WHERE room=?1 AND route_epoch=?2 AND activity_id=?3`)
    .bind(input.room, input.routeEpoch, input.activityId).first<ActivityRow>();
  if (row?.end_reason) {
    if (row.next_retry_at !== null && row.next_retry_at <= Date.now() && row.attempts < MAX_END_ATTEMPTS)
      await attemptEnd(env, row, Date.now());
    return json({ error: "activity_ended" }, 409);
  }
  // The room may have ended and drained its queue before this D1 insert. A concurrent pairing
  // cleanup may also have removed our active row. Atomically leave a terminal address that
  // cleanup will preserve, so the suspended phone still receives an end push.
  if (!(await clientAllowed(env, input, true))) {
    const now = Date.now();
    await env.DB.prepare(`INSERT INTO activity_registrations
      (room,route_epoch,activity_id,push_token,environment,version,updated_at,end_reason,end_at,next_retry_at,attempts)
      VALUES (?1,?2,?3,?4,?5,1,?6,'error',?6,?6,0)
      ON CONFLICT(room,route_epoch,activity_id) DO UPDATE SET
        end_reason=COALESCE(activity_registrations.end_reason,'error'),
        end_at=COALESCE(activity_registrations.end_at,?6),
        next_retry_at=COALESCE(activity_registrations.next_retry_at,?6), attempts=0`)
      .bind(input.room, input.routeEpoch, input.activityId, input.pushToken, input.environment, now).run();
    await endRoomActivities(env, input.room, input.routeEpoch, "error");
    return json({ error: "unauthorized_or_stale_route" }, 401);
  }
  return json({ state: "registered" }, 200);
}

export async function handleActivityRemove(request: Request, env: Env): Promise<Response> {
  const input = identity(await body(request));
  if (!input) return json({ error: "invalid_request" }, 400);
  if (!(await clientAllowed(env, input, false))) return json({ error: "unauthorized" }, 401);
  if (!(await allowStrict(env.RL_API_DEVICE, `activity:${input.room}`, "RL_API_DEVICE")))
    return json({ error: "rate_limited" }, 429, { "retry-after": "60" });
  const now = Date.now();
  // Removal is terminal for this ActivityKit ID. Keep a short-lived tombstone, otherwise a
  // delayed pushTokenUpdates callback could insert the same activity again while the route lives.
  await env.DB.prepare(`INSERT INTO activity_registrations
    (room,route_epoch,activity_id,push_token,environment,version,updated_at,end_reason,end_at,next_retry_at,attempts,local_removed)
    VALUES (?1,?2,?3,?4,?5,1,?6,'user',?6,NULL,?7,1)
    ON CONFLICT(room,route_epoch,activity_id) DO UPDATE SET
      end_reason=COALESCE(activity_registrations.end_reason,'user'),
      end_at=COALESCE(activity_registrations.end_at,?6), version=activity_registrations.version+1,
      next_retry_at=NULL, attempts=?7, local_removed=1 WHERE activity_registrations.push_token=excluded.push_token
      AND activity_registrations.environment=excluded.environment`)
    .bind(input.room, input.routeEpoch, input.activityId, input.pushToken, input.environment, now, MAX_END_ATTEMPTS).run();
  return new Response(null, { status: 204 });
}

async function sendEnd(env: PushEnv, row: ActivityRow, reason: string): Promise<Response> {
  const now = Math.floor(Date.now() / 1000);
  const ended = Math.floor(row.end_at! / 1000);
  const payload = {
    aps: {
      timestamp: ended, event: "end",
      "content-state": { phase: "ended", endedReason: reason },
      "dismissal-date": ended - 1,
    },
  };
  const host = row.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  return fetch(`https://${host}/3/device/${row.push_token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await apnsToken(env)}`,
      "apns-push-type": "liveactivity",
      "apns-topic": `${env.APP_BUNDLE_ID}.push-type.liveactivity`,
      "apns-priority": "10",
      "apns-expiration": String(Math.min(now + 300, ended + END_RETRY_LIFETIME / 1000)),
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
}

type EndOutcome = "accepted" | "failed" | "invalidToken" | "superseded";
async function attemptEnd(env: Env, row: ActivityRow, now: number): Promise<EndOutcome> {
  const current = await env.DB.prepare(`SELECT version,push_token,end_at FROM activity_registrations
    WHERE room=?1 AND route_epoch=?2 AND activity_id=?3`)
    .bind(row.room, row.route_epoch, row.activity_id)
    .first<{ version: number; push_token: string; end_at: number | null }>();
  if (current?.version !== row.version || current.push_token !== row.push_token || current.end_at !== row.end_at)
    return "superseded";
  let status: number | undefined;
  try {
    if (!configured(env as PushEnv)) throw new Error("activity_push_unavailable");
    status = (await sendEnd(env as PushEnv, row, row.end_reason!)).status;
  } catch { /* A transient APNs or configuration failure is scheduled for retry. */ }
  if (status === 200 || status === 410) {
    // Retain a short-lived terminal row after APNs accepts the end. Otherwise a delayed
    // pushTokenUpdates callback could recreate the same ActivityKit ID while its route lives.
    // The version fence also keeps a rotated token pending when an older APNs reply arrives.
    await env.DB.prepare(`UPDATE activity_registrations SET next_retry_at=NULL, attempts=?7
      WHERE room=?1 AND route_epoch=?2 AND activity_id=?3 AND push_token=?4 AND version=?5 AND end_at=?6`)
      .bind(row.room, row.route_epoch, row.activity_id, row.push_token, row.version, row.end_at, MAX_END_ATTEMPTS).run();
    return status === 200 ? "accepted" : "invalidToken";
  }
  const delay = Math.min(4 * 60_000, 60_000 * 2 ** Math.min(row.attempts, 3));
  await env.DB.prepare(`UPDATE activity_registrations
    SET attempts=attempts+1, next_retry_at=?6
    WHERE room=?1 AND route_epoch=?2 AND activity_id=?3 AND push_token=?4 AND version=?5 AND end_at=?7`)
    .bind(row.room, row.route_epoch, row.activity_id, row.push_token, row.version,
      Math.min(now + delay, row.end_at! + END_RETRY_LIFETIME), row.end_at).run();
  return "failed";
}

const emptyResult = () => ({ accepted: 0, failed: 0, invalidToken: 0 });
function count(result: ReturnType<typeof emptyResult>, outcome: EndOutcome): void {
  if (outcome !== "superseded") result[outcome]++;
}

/** The caller captures the old route epoch before clearing it. Failed sends stay pending for retry. */
export async function endRoomActivities(
  env: Env, room: string, routeEpoch: string, reason: "macStopped" | "timeout" | "user" | "error",
  endedAt: number = Date.now(),
): Promise<{ accepted: number; failed: number; invalidToken: number }> {
  if (!HEX64.test(room) || !EPOCH.test(routeEpoch) || !REASONS.has(reason)) throw new Error("invalid_activity_end");
  const now = Date.now();
  if (!Number.isSafeInteger(endedAt) || endedAt <= 0 || endedAt > now) throw new Error("invalid_activity_end_time");
  await env.DB.prepare(`UPDATE activity_registrations
    SET end_reason=?3, end_at=?4, next_retry_at=?4, attempts=0
    WHERE room=?1 AND route_epoch=?2 AND end_reason IS NULL`).bind(room, routeEpoch, reason, endedAt).run();
  await env.DB.prepare(`DELETE FROM activity_registrations
    WHERE room=?1 AND route_epoch=?2 AND end_at IS NOT NULL AND end_at<=?3`)
    .bind(room, routeEpoch, now - END_RETRY_LIFETIME).run();
  const rows = await env.DB.prepare(`SELECT room,route_epoch,activity_id,push_token,environment,version,end_reason,end_at,next_retry_at,attempts
    FROM activity_registrations WHERE room=?1 AND route_epoch=?2 AND next_retry_at IS NOT NULL`)
    .bind(room, routeEpoch).all<ActivityRow>();
  const result = emptyResult();
  for (const row of rows.results) count(result, await attemptEnd(env, row, now));
  return result;
}

/** Minute cron drains due end events even after the room was forgotten or blocked. */
export async function retryPendingActivityEnds(env: Env, now = Date.now()): Promise<{
  accepted: number; failed: number; invalidToken: number; expired: number;
}> {
  const expired = await env.DB.prepare(`DELETE FROM activity_registrations
    WHERE end_at IS NOT NULL AND end_at<=?1`).bind(now - END_RETRY_LIFETIME).run();
  const rows = await env.DB.prepare(`SELECT room,route_epoch,activity_id,push_token,environment,version,end_reason,end_at,next_retry_at,attempts
    FROM activity_registrations WHERE end_reason IS NOT NULL AND next_retry_at<=?1 AND attempts<?2
    ORDER BY next_retry_at LIMIT 100`).bind(now, MAX_END_ATTEMPTS).all<ActivityRow>();
  const result = emptyResult();
  for (const row of rows.results) count(result, await attemptEnd(env, row, now));
  return { ...result, expired: expired.meta.changes ?? 0 };
}

export async function purgeActivityRetention(db: D1Database, now: number): Promise<void> {
  // An ActivityKit session cannot remain useful indefinitely; stale push addresses have no purpose.
  await db.prepare("DELETE FROM activity_registrations WHERE end_reason IS NULL AND updated_at<?1")
    .bind(now - 24 * 60 * 60_000).run();
}
