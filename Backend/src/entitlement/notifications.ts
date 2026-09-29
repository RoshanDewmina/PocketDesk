import { JwsVerificationError, verifyAppleJws } from "../apple/jws";
import type { Config } from "../config";
import { fingerprint, log, logError } from "../log";
import { allow } from "../ratelimit";
import type { RoomDO } from "../room";
import { BodyTooLarge, isRecord, json, readJsonBody } from "../util";
import { audit, devicesForEntitlement, entitlementIdFor, getEntitlement, markStatus, recordNotification, upsertEntitlement } from "./store";
import { checkTransactionPolicy, parseTransactionPayload, statusFromTransaction, type TransactionInfo } from "./verify";

const MAX_BODY_BYTES = 32 * 1024;

type RenewalInfo = { gracePeriodExpiresDate?: number; originalTransactionId?: string };

function parseRenewalInfo(payload: Record<string, unknown>): RenewalInfo {
  return {
    gracePeriodExpiresDate: typeof payload.gracePeriodExpiresDate === "number" ? payload.gracePeriodExpiresDate : undefined,
    originalTransactionId: typeof payload.originalTransactionId === "string" ? payload.originalTransactionId : undefined,
  };
}

async function verifyEmbedded(compact: unknown, config: Config, now: number): Promise<Record<string, unknown> | undefined> {
  if (typeof compact !== "string" || compact.length === 0 || compact.length > 16 * 1024) return undefined;
  return (await verifyAppleJws(compact, { roots: config.roots, now })).payload;
}

export type NotificationOutcome = "recorded" | "duplicate" | "applied" | "ignored_other_app";

export async function applyNotification(env: Env, config: Config, decoded: Record<string, unknown>, now: number): Promise<NotificationOutcome> {
  const notificationType = typeof decoded.notificationType === "string" ? decoded.notificationType : "UNKNOWN";
  const subtype = typeof decoded.subtype === "string" ? decoded.subtype : undefined;
  const uuid = typeof decoded.notificationUUID === "string" && decoded.notificationUUID.length <= 64 ? decoded.notificationUUID : undefined;
  const data = isRecord(decoded.data) ? decoded.data : undefined;
  const environment = typeof data?.environment === "string" ? data.environment : undefined;

  if (data && typeof data.bundleId === "string" && data.bundleId !== config.bundleId) return "ignored_other_app";
  if (data && environment === "Production" && config.appAppleId !== undefined && data.appAppleId !== config.appAppleId) return "ignored_other_app";

  let tx: TransactionInfo | undefined;
  let renewal: RenewalInfo = {};
  if (data) {
    const txPayload = await verifyEmbedded(data.signedTransactionInfo, config, now);
    if (txPayload) tx = parseTransactionPayload(txPayload);
    const renewalPayload = await verifyEmbedded(data.signedRenewalInfo, config, now);
    if (renewalPayload) renewal = parseRenewalInfo(renewalPayload);
  }
  const originalTransactionId = tx?.originalTransactionId ?? renewal.originalTransactionId;
  const entitlementId = originalTransactionId ? await entitlementIdFor(env.ENTITLEMENT_HASH_KEY, originalTransactionId) : undefined;

  if (uuid) {
    const fresh = await recordNotification(env.DB, { uuid, type: notificationType, subtype, environment, entitlementId }, now);
    if (!fresh) return "duplicate";
  }
  log("notification", { type: notificationType, subtype, environment, entitlement: fingerprint(entitlementId) });
  if (!tx || !entitlementId) return "recorded";
  if (checkTransactionPolicy(tx, config) === "wrong_product" && !config.allowedProductIds.has(tx.productId)) return "recorded";

  const existing = await getEntitlement(env.DB, entitlementId);
  const txEnvironment = tx.environment === "LocalTesting" ? "Xcode" : tx.environment;
  const expiresAt = Math.max(tx.expiresDate ?? 0, existing?.expires_at ?? 0);
  const base = { id: entitlementId, productId: tx.productId, environment: txEnvironment, expiresAt, source: "notification" as const };

  switch (notificationType) {
    case "SUBSCRIBED":
    case "DID_RENEW":
    case "OFFER_REDEEMED":
    case "DID_CHANGE_RENEWAL_PREF":
    case "REFUND_REVERSED":
    case "RENEWAL_EXTENDED":
      await upsertEntitlement(env.DB, { ...base, status: statusFromTransaction({ ...tx, expiresDate: expiresAt }, now), graceUntil: null, revokedAt: null }, now);
      break;
    case "DID_FAIL_TO_RENEW":
      if (subtype === "GRACE_PERIOD" && renewal.gracePeriodExpiresDate) {
        await upsertEntitlement(env.DB, { ...base, status: "grace", graceUntil: renewal.gracePeriodExpiresDate, revokedAt: null }, now);
      } else {
        await upsertEntitlement(env.DB, { ...base, status: expiresAt > now ? "active" : "expired", graceUntil: existing?.grace_until ?? null }, now);
      }
      break;
    case "EXPIRED":
    case "GRACE_PERIOD_EXPIRED":
      await upsertEntitlement(env.DB, { ...base, status: "expired", graceUntil: null }, now);
      break;
    case "REFUND":
    case "REVOKE":
      await upsertEntitlement(env.DB, { ...base, status: "revoked", graceUntil: null, revokedAt: tx.revocationDate ?? now }, now);
      await pushRevocation(env, entitlementId, now);
      break;
    default:
      if (existing) await markStatus(env.DB, entitlementId, existing.status, now);
      return "recorded";
  }
  await audit(env.DB, "notification_applied", { entitlementId, detail: `${notificationType}${subtype ? `/${subtype}` : ""}` }, now);
  return "applied";
}

async function pushRevocation(env: Env, entitlementId: string, now: number): Promise<void> {
  const rooms = env.ROOM as unknown as DurableObjectNamespace<RoomDO>;
  for (const device of await devicesForEntitlement(env.DB, entitlementId)) {
    if (!device.last_room) continue;
    try {
      await rooms.get(rooms.idFromName(device.last_room)).revokeEntitlement(entitlementId);
    } catch (error) {
      logError("revoke_push_failed", error, { room: fingerprint(device.last_room) });
    }
  }
  await audit(env.DB, "entitlement_revoked", { entitlementId }, now);
}

export async function handleNotification(request: Request, env: Env, config: Config): Promise<Response> {
  const now = Date.now();
  if (!(await allow(env.RL_NOTIFY, request.headers.get("cf-connecting-ip") ?? "unknown", "RL_NOTIFY"))) return json({ error: "rate_limited" }, 429);
  let body: unknown;
  try {
    body = await readJsonBody(request, MAX_BODY_BYTES);
  } catch (error) {
    if (error instanceof BodyTooLarge) return json({ error: "invalid_request" }, 400);
    throw error;
  }
  if (!isRecord(body) || typeof body.signedPayload !== "string") return json({ error: "invalid_request" }, 400);
  if (config.roots.length === 0) return json({ error: "unavailable" }, 503);
  let decoded: Record<string, unknown>;
  try {
    decoded = (await verifyAppleJws(body.signedPayload, { roots: config.roots, now })).payload;
  } catch (error) {
    if (error instanceof JwsVerificationError) {
      log("notification_rejected", { reason: error.reason });
      return json({ error: "invalid_signature" }, 401);
    }
    throw error;
  }
  try {
    const outcome = await applyNotification(env, config, decoded, now);
    return json({ ok: true, outcome });
  } catch (error) {
    logError("notification_failed", error);
    return json({ error: "unavailable" }, 503);
  }
}
