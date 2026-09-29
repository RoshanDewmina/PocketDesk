import { appleApiConfigFromEnv, getTestNotificationStatus, requestTestNotification } from "./apple/server-api";
import type { Config } from "./config";
import { deleteRoom, readinessCounts, roomStatus, setRoomStatus } from "./entitlement/store";
import { fingerprint, log, logError } from "./log";
import { addressKey, allow } from "./ratelimit";
import type { RoomDO } from "./room";
import { BodyTooLarge, HEX64, isRecord, json, readJsonBody, secureEqual, sha256Hex } from "./util";

const rooms = (env: Env) => env.ROOM as unknown as DurableObjectNamespace<RoomDO>;

export function health(): Response {
  return json({ status: "ok", protocol: 1 });
}

export async function isAdmin(request: Request, env: Env): Promise<boolean> {
  if (!env.ADMIN_TOKEN || env.ADMIN_TOKEN.length < 32) return false;
  const header = request.headers.get("authorization") ?? "";
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  return presented.length > 0 && (await secureEqual(presented, env.ADMIN_TOKEN));
}

export async function ready(env: Env, config: Config): Promise<Response> {
  const now = Date.now();
  const reasons: string[] = [];
  if (!config.relayConfigured) reasons.push("relay_not_configured");
  if (config.roots.length === 0) reasons.push("apple_roots_not_configured");
  if (!env.ENTITLEMENT_TOKEN_KEY || env.ENTITLEMENT_TOKEN_KEY.length < 32) reasons.push("entitlement_token_key_missing");
  if (!env.ENTITLEMENT_HASH_KEY || env.ENTITLEMENT_HASH_KEY.length < 32) reasons.push("entitlement_hash_key_missing");
  if (config.appAppleId === undefined && config.isProduction) reasons.push("app_apple_id_not_configured");
  let counts: Record<string, number> | undefined;
  try {
    counts = await readinessCounts(env.DB, now);
  } catch (error) {
    logError("readiness_counts_failed", error);
    reasons.push("database_unavailable");
  }
  const ready = reasons.length === 0;
  return json({
    status: ready ? "ready" : "not_ready",
    environment: config.environmentName,
    protocol: 1,
    reasons,
    relay: { provider: config.relayConfigured ? "cloudflare" : "none", policy: config.testForceRelay ? "relay" : "all", credentialSeconds: config.turnTtlSeconds },
    lease: { leaseSeconds: config.leaseMs / 1000 },
    apple: { roots: config.roots.length, serverApi: Boolean(env.APPLE_IAP_KEY_ID), sandboxAccepted: config.acceptSandbox },
    counts,
  }, ready ? 200 : 503);
}

export async function adminRoom(request: Request, env: Env, room: string, action: string): Promise<Response> {
  if (!HEX64.test(room)) return json({ error: "invalid_request" }, 400);
  const now = Date.now();
  const stub = rooms(env).get(rooms(env).idFromName(room));
  if (action === "block") {
    await setRoomStatus(env.DB, room, "blocked", now);
    await stub.block();
    log("room_blocked", { room: fingerprint(room) });
    return json({ ok: true, status: "blocked" });
  }
  if (action === "unblock") {
    await setRoomStatus(env.DB, room, "active", now);
    await stub.unblock();
    return json({ ok: true, status: "active" });
  }
  if (action === "status") return json(await stub.snapshot());
  return json({ error: "not_found" }, 404);
}

export async function adminTestNotification(request: Request, env: Env, config: Config): Promise<Response> {
  const environment = new URL(request.url).searchParams.get("environment") === "Sandbox" ? "Sandbox" : "Production";
  const apple = appleApiConfigFromEnv(env, environment);
  if (!apple) return json({ error: "apple_server_api_not_configured" }, 503);
  void config;
  const token = new URL(request.url).searchParams.get("token");
  const result = token
    ? await getTestNotificationStatus(apple, token, Date.now())
    : await requestTestNotification(apple, Date.now());
  return json({ appleStatus: result.status, body: result.body }, result.status >= 200 && result.status < 300 ? 200 : 502);
}

/** The Mac's "Remove this Mac and delete server data": proves room ownership with the host token. A blocked room stays blocked. */
export async function forgetRoom(request: Request, env: Env): Promise<Response> {
  if (!(await allow(env.RL_API_IP, addressKey(request.headers.get("cf-connecting-ip")), "RL_API_IP"))) return json({ error: "rate_limited" }, 429);
  let body: unknown;
  try {
    body = await readJsonBody(request, 4096);
  } catch (error) {
    if (error instanceof BodyTooLarge) return json({ error: "invalid_request" }, 400);
    throw error;
  }
  if (!isRecord(body) || typeof body.room !== "string" || !HEX64.test(body.room) || typeof body.token !== "string" || !HEX64.test(body.token)) {
    return json({ error: "invalid_request" }, 400);
  }
  if (!(await secureEqual(await sha256Hex(body.token), body.room))) return json({ error: "unauthorized" }, 401);
  if ((await roomStatus(env.DB, body.room)) === "blocked") return json({ error: "blocked" }, 403);
  await rooms(env).get(rooms(env).idFromName(body.room)).forget();
  await deleteRoom(env.DB, body.room);
  log("room_forgotten", { room: fingerprint(body.room) });
  return new Response(null, { status: 204 });
}
