import { JwsVerificationError, verifyAppleJws } from "../apple/jws";
import type { Config } from "../config";
import { fingerprint, log, logError } from "../log";
import { addressKey, allow } from "../ratelimit";
import type { RoomDO } from "../room";
import { BodyTooLarge, isRecord, json, readJsonBody } from "../util";
import {
  appTransactionHashFor, audit, devicesForEntitlement, entitlementIdFor, getEntitlement, notificationSeen, recordNotification, stopForConsent,
  upsertEntitlement, type EntitlementRow, type EntitlementStatus,
} from "./store";
import { checkTransactionPolicy, ownershipForLog, parseTransactionPayload, statusFromTransaction, type TransactionInfo } from "./verify";

// A V2 notification wraps two further JWS (transaction and renewal info), each with its own three-certificate
// chain, so the outer token is several times the size of a bare transaction.
const MAX_BODY_BYTES = 96 * 1024;
const MAX_OUTER_JWS_CHARS = 64 * 1024;
const MAX_EMBEDDED_JWS_CHARS = 16 * 1024;

type RenewalInfo = { gracePeriodExpiresDate?: number; originalTransactionId?: string };

function parseRenewalInfo(payload: Record<string, unknown>): RenewalInfo {
  return {
    gracePeriodExpiresDate: typeof payload.gracePeriodExpiresDate === "number" ? payload.gracePeriodExpiresDate : undefined,
    originalTransactionId: typeof payload.originalTransactionId === "string" ? payload.originalTransactionId : undefined,
  };
}

async function verifyEmbedded(compact: unknown, config: Config, now: number): Promise<Record<string, unknown> | undefined> {
  if (typeof compact !== "string" || compact.length === 0 || compact.length > MAX_EMBEDDED_JWS_CHARS) return undefined;
  return (await verifyAppleJws(compact, { roots: config.roots, now, maxChars: MAX_EMBEDDED_JWS_CHARS })).payload;
}

export type NotificationOutcome = "recorded" | "duplicate" | "applied" | "ignored_other_app";

/** A seat an organization or group assigned, or took back. Anywhere never grants one, so it never changes a purchaser's row. */
const isNotOwnPurchase = (tx: TransactionInfo) => tx.inAppOwnershipType !== "PURCHASED" || tx.revocationType === "ASSIGNMENT_REVOKE";

const APP_RECEIPT_TYPES = new Set(["Production", "Sandbox", "Xcode", "LocalTesting"]);

/** A refund is undone only by REFUND_REVERSED or by a purchase made after it; nothing older may clear it. */
function resolveRevokedAt(existing: EntitlementRow | null, tx: TransactionInfo, notificationType: string): number | null {
  if (tx.revocationDate !== undefined) return tx.revocationDate;
  const current = existing?.revoked_at ?? null;
  if (current === null) return null;
  if (notificationType === "REFUND_REVERSED") return null;
  return (tx.purchaseDate ?? 0) > current ? null : current;
}

export async function applyNotification(env: Env, config: Config, decoded: Record<string, unknown>, now: number): Promise<NotificationOutcome> {
  const notificationType = typeof decoded.notificationType === "string" ? decoded.notificationType : "UNKNOWN";
  const subtype = typeof decoded.subtype === "string" ? decoded.subtype : undefined;
  const uuid = typeof decoded.notificationUUID === "string" && decoded.notificationUUID.length <= 64 ? decoded.notificationUUID : undefined;
  const data = isRecord(decoded.data) ? decoded.data : undefined;
  // RESCIND_CONSENT carries `appData` (app metadata plus a signed app transaction) instead of `data`.
  const appData = !data && isRecord(decoded.appData) ? decoded.appData : undefined;
  const container = data ?? appData;
  const rawEnvironment = typeof container?.environment === "string" ? container.environment : undefined;
  const environment = rawEnvironment?.toLowerCase() === "production" ? "Production" : rawEnvironment?.toLowerCase() === "sandbox" ? "Sandbox" : rawEnvironment;

  if (container && typeof container.bundleId === "string" && container.bundleId !== config.bundleId) return "ignored_other_app";
  if (container && environment === "Production" && config.appAppleId !== undefined && container.appAppleId !== config.appAppleId) return "ignored_other_app";
  if (uuid && (await notificationSeen(env.DB, uuid))) return "duplicate";

  if (notificationType === "RESCIND_CONSENT") return applyConsentRescinded(env, config, appData, { uuid, subtype, environment }, now);

  let tx: TransactionInfo | undefined;
  let renewal: RenewalInfo = {};
  if (data) {
    const txPayload = await verifyEmbedded(data.signedTransactionInfo, config, now);
    if (txPayload) tx = parseTransactionPayload(txPayload);
    const renewalPayload = await verifyEmbedded(data.signedRenewalInfo, config, now);
    if (renewalPayload) renewal = parseRenewalInfo(renewalPayload);
  }
  const seat = tx !== undefined && isNotOwnPurchase(tx);
  const originalTransactionId = seat ? undefined : tx?.originalTransactionId ?? renewal.originalTransactionId;
  const entitlementId = originalTransactionId ? await entitlementIdFor(env.ENTITLEMENT_HASH_KEY, originalTransactionId) : undefined;
  log("notification", { type: notificationType, subtype, environment, entitlement: fingerprint(entitlementId) });

  // The dedupe row is written last: if applying fails, Apple's retry is applied instead of being dropped as a duplicate.
  const finish = async (outcome: NotificationOutcome) => {
    if (uuid) await recordNotification(env.DB, { uuid, type: notificationType, subtype, environment, entitlementId }, now);
    return outcome;
  };

  if (tx && seat) {
    // Multiseat: an assigned seat was never entitled, so an assignment or its revocation (ASSIGNMENT_REVOKE)
    // is recorded and left alone. Logged by kind only; the seat's transaction ids go nowhere.
    log("notification_seat_ignored", { type: notificationType, ownership: ownershipForLog(tx), assignmentRevoke: tx.revocationType === "ASSIGNMENT_REVOKE" });
    return finish("recorded");
  }
  if (!tx || !entitlementId) return finish("recorded");
  const policy = checkTransactionPolicy(tx, config);
  if (policy && policy !== "environment_not_accepted") return finish("recorded");

  const existing = await getEntitlement(env.DB, entitlementId);
  const txEnvironment = tx.environment === "LocalTesting" ? "Xcode" : tx.environment;
  const expiresAt = Math.max(tx.expiresDate ?? 0, existing?.expires_at ?? 0);
  const revokedAt = resolveRevokedAt(existing, tx, notificationType);
  const base = { id: entitlementId, productId: tx.productId, environment: txEnvironment, expiresAt, revokedAt,
    purchaseAt: tx.purchaseDate, refundReversed: notificationType === "REFUND_REVERSED", source: "notification" as const };
  const statusFor = (fallback: EntitlementStatus): EntitlementStatus => revokedAt !== null ? "revoked" : fallback;

  switch (notificationType) {
    case "SUBSCRIBED":
    case "DID_RENEW":
    case "OFFER_REDEEMED":
    case "REFUND_REVERSED":
    case "RENEWAL_EXTENDED":
      // A payment happened: the subscription is current again and any grace period is over.
      await upsertEntitlement(env.DB, { ...base, status: statusFor(statusFromTransaction({ ...tx, expiresDate: expiresAt, revocationDate: revokedAt ?? undefined }, now)), graceUntil: null }, now);
      break;
    case "DID_CHANGE_RENEWAL_PREF":
    case "DID_CHANGE_RENEWAL_STATUS":
    case "PRICE_INCREASE":
      // Preference changes carry no payment: keep the current access state, refresh product and expiry only.
      await upsertEntitlement(env.DB, {
        ...base,
        status: statusFor(existing?.status ?? statusFromTransaction({ ...tx, expiresDate: expiresAt }, now)),
        graceUntil: existing?.grace_until ?? null,
      }, now);
      break;
    case "DID_FAIL_TO_RENEW":
      if (subtype === "GRACE_PERIOD" && renewal.gracePeriodExpiresDate) {
        await upsertEntitlement(env.DB, { ...base, status: statusFor("grace"), graceUntil: renewal.gracePeriodExpiresDate }, now);
      } else {
        await upsertEntitlement(env.DB, { ...base, status: statusFor(expiresAt > now ? "active" : "expired"), graceUntil: existing?.grace_until ?? null }, now);
      }
      break;
    case "EXPIRED":
    case "GRACE_PERIOD_EXPIRED":
      await upsertEntitlement(env.DB, { ...base, status: statusFor("expired"), graceUntil: null }, now);
      break;
    case "REFUND":
    case "REVOKE": {
      // A refund of an earlier period leaves a newer paid period untouched.
      const refundedPeriodEnd = tx.expiresDate ?? 0;
      if (existing && refundedPeriodEnd > 0 && refundedPeriodEnd < existing.expires_at && existing.revoked_at === null) {
        await audit(env.DB, "refund_of_earlier_period", { entitlementId }, now);
        return finish("recorded");
      }
      const applied = await upsertEntitlement(env.DB, { ...base, status: "revoked", graceUntil: null, revokedAt: tx.revocationDate ?? now }, now);
      if (!applied) return finish("recorded");
      await pushRevocation(env, entitlementId, now);
      break;
    }
    default:
      return finish("recorded");
  }
  await audit(env.DB, "notification_applied", { entitlementId, detail: `${notificationType}${subtype ? `/${subtype}` : ""}` }, now);
  return finish("applied");
}

type NotificationMeta = { uuid?: string; subtype?: string; environment?: string };

/**
 * A parent or guardian withdrew consent for a child's use of the app (Texas SB 2420 and similar laws).
 * Apple names the app transaction, not a subscription, so every Anywhere subscription verified under that
 * app transaction stops, its live rooms end, and later verifications under it are refused.
 */
async function applyConsentRescinded(env: Env, config: Config, appData: Record<string, unknown> | undefined, meta: NotificationMeta, now: number): Promise<NotificationOutcome> {
  const finish = async (outcome: NotificationOutcome) => {
    if (meta.uuid) await recordNotification(env.DB, { uuid: meta.uuid, type: "RESCIND_CONSENT", subtype: meta.subtype, environment: meta.environment }, now);
    return outcome;
  };
  let app: Record<string, unknown> | undefined;
  try {
    app = appData ? await verifyEmbedded(appData.signedAppTransactionInfo, config, now) : undefined;
  } catch (error) {
    if (!(error instanceof JwsVerificationError)) throw error;
  }
  const appTransactionId = typeof app?.appTransactionId === "string" && app.appTransactionId.length > 0 && app.appTransactionId.length <= 64 ? app.appTransactionId : undefined;
  const receiptType = typeof app?.receiptType === "string" && APP_RECEIPT_TYPES.has(app.receiptType) ? app.receiptType : undefined;
  if (!app || app.bundleId !== config.bundleId || !appTransactionId || !receiptType) {
    log("notification_consent_unusable", { environment: meta.environment });
    return finish("recorded");
  }
  if (receiptType === "Sandbox" && !config.acceptSandbox) return finish("recorded");
  if ((receiptType === "Xcode" || receiptType === "LocalTesting") && !config.allowXcode) return finish("recorded");

  const appTransactionHash = await appTransactionHashFor(env.ENTITLEMENT_HASH_KEY, appTransactionId);
  const stopped = await stopForConsent(env.DB, appTransactionHash, receiptType === "LocalTesting" ? "Xcode" : receiptType, now);
  for (const entitlementId of stopped) {
    await pushRevocation(env, entitlementId, now);
    await audit(env.DB, "consent_rescinded", { entitlementId }, now);
  }
  log("notification_consent_rescinded", { environment: meta.environment, subscriptions: stopped.length });
  return finish("applied");
}

async function pushRevocation(env: Env, entitlementId: string, now: number): Promise<void> {
  const rooms = env.ROOM as unknown as DurableObjectNamespace<RoomDO>;
  for (const device of await devicesForEntitlement(env.DB, entitlementId)) {
    if (!device.last_room) continue;
    try {
      await rooms.get(rooms.idFromName(device.last_room)).revokeEntitlement(entitlementId, device.device_id, true);
    } catch (error) {
      logError("revoke_push_failed", error, { room: fingerprint(device.last_room) });
    }
  }
  await audit(env.DB, "entitlement_revoked", { entitlementId }, now);
}

export async function handleNotification(request: Request, env: Env, config: Config): Promise<Response> {
  const now = Date.now();
  if (!(await allow(env.RL_NOTIFY, addressKey(request.headers.get("cf-connecting-ip")), "RL_NOTIFY"))) return json({ error: "rate_limited" }, 429);
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
    decoded = (await verifyAppleJws(body.signedPayload, { roots: config.roots, now, maxChars: MAX_OUTER_JWS_CHARS })).payload;
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
