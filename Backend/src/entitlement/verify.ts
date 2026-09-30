import { decodeJwsUnverified, JwsVerificationError, verifyAppleJws } from "../apple/jws";
import type { Config } from "../config";
import { fingerprint, log, logError } from "../log";
import { addressKey, allow } from "../ratelimit";
import type { RoomDO } from "../room";
import { BodyTooLarge, HEX64, isoFromMs, isRecord, json, readJsonBody } from "../util";
import {
  appTransactionHashFor, audit, consentStopped, entitlementForDevice, entitlementIdFor, getEntitlement, hasAccess, linkDevice, unlinkDeviceIfInRoom,
  upsertEntitlement, type EntitlementStatus,
} from "./store";
import { environmentLetter, MAX_TOKEN_TTL_MS, mintEntitlementToken, verifyEntitlementToken } from "./token";

const MAX_BODY_BYTES = 32 * 1024;
const MAX_JWS_CHARS = 16 * 1024;

export type TransactionInfo = {
  originalTransactionId: string;
  transactionId: string;
  productId: string;
  bundleId: string;
  environment: "Production" | "Sandbox" | "Xcode" | "LocalTesting";
  type: string;
  expiresDate?: number;
  revocationDate?: number;
  signedDate?: number;
  purchaseDate?: number;
  /** PURCHASED, FAMILY_SHARED or ASSIGNED (a multiseat seat an organization or group handed out). */
  inAppOwnershipType?: string;
  /** REFUND_FULL, REFUND_PRORATED, FAMILY_REVOKE or ASSIGNMENT_REVOKE. */
  revocationType?: string;
  appTransactionId?: string;
};

const optionalNumber = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : undefined);
const optionalString = (value: unknown, max: number) => (typeof value === "string" && value.length > 0 && value.length <= max ? value : undefined);

const OWNERSHIP_LOG_VALUES = new Set(["PURCHASED", "FAMILY_SHARED", "ASSIGNED"]);
/** A fixed vocabulary for logs, so a payload can never write free text into them. */
export const ownershipForLog = (tx: Pick<TransactionInfo, "inAppOwnershipType">) =>
  tx.inAppOwnershipType === undefined ? "missing" : OWNERSHIP_LOG_VALUES.has(tx.inAppOwnershipType) ? tx.inAppOwnershipType : "other";

export function parseTransactionPayload(payload: Record<string, unknown>): TransactionInfo | undefined {
  const { originalTransactionId, transactionId, productId, bundleId, environment, type } = payload;
  if (typeof originalTransactionId !== "string" || originalTransactionId.length === 0 || originalTransactionId.length > 64) return undefined;
  if (typeof transactionId !== "string" || transactionId.length > 64) return undefined;
  if (typeof productId !== "string" || productId.length > 128 || typeof bundleId !== "string" || bundleId.length > 128) return undefined;
  if (environment !== "Production" && environment !== "Sandbox" && environment !== "Xcode" && environment !== "LocalTesting") return undefined;
  if (typeof type !== "string") return undefined;
  return {
    originalTransactionId, transactionId, productId, bundleId, environment, type,
    expiresDate: optionalNumber(payload.expiresDate),
    revocationDate: optionalNumber(payload.revocationDate),
    signedDate: optionalNumber(payload.signedDate),
    purchaseDate: optionalNumber(payload.purchaseDate),
    inAppOwnershipType: optionalString(payload.inAppOwnershipType, 32),
    revocationType: optionalString(payload.revocationType, 32),
    appTransactionId: optionalString(payload.appTransactionId, 64),
  };
}

export type PolicyFailure = "wrong_app" | "wrong_product" | "environment_not_accepted" | "not_subscription" | "not_purchased";

export function checkTransactionPolicy(tx: TransactionInfo, config: Config): PolicyFailure | undefined {
  // JWSTransactionDecodedPayload identifies the app by bundleId; appAppleId belongs
  // to the outer production notification and is checked there, not on transactions.
  if (tx.bundleId !== config.bundleId) return "wrong_app";
  if (tx.environment === "Sandbox" && !config.acceptSandbox) return "environment_not_accepted";
  if ((tx.environment === "Xcode" || tx.environment === "LocalTesting") && !config.allowXcode) return "environment_not_accepted";
  if (!config.allowedProductIds.has(tx.productId)) return "wrong_product";
  if (tx.type !== "Auto-Renewable Subscription") return "not_subscription";
  // Anywhere is a personal plan: Family Sharing and multiseat are off in App Store Connect, and a seat
  // assigned by an organization or group is refused even if that setting is ever changed.
  if (tx.inAppOwnershipType !== "PURCHASED") return "not_purchased";
  return undefined;
}

export type SignatureFailure = "signature" | PolicyFailure;

/** Verifies a StoreKit / App Store JWS and applies the product policy. Xcode transactions are decoded unverified only when allowed. */
export type VerifiedTransaction = { ok: true; tx: TransactionInfo } | { ok: false; reason: SignatureFailure; ownership?: string };

const policyResult = (tx: TransactionInfo, policy: PolicyFailure | undefined): VerifiedTransaction =>
  policy === undefined ? { ok: true, tx } : policy === "not_purchased" ? { ok: false, reason: policy, ownership: ownershipForLog(tx) } : { ok: false, reason: policy };

export async function verifyTransactionJws(compact: string, config: Config, now: number): Promise<VerifiedTransaction> {
  if (typeof compact !== "string" || compact.length === 0 || compact.length > MAX_JWS_CHARS) return { ok: false, reason: "signature" };
  let payload: Record<string, unknown>;
  if (config.allowXcode && !config.isProduction) {
    try {
      const decoded = decodeJwsUnverified(compact);
      const environment = decoded.payload.environment;
      if (environment === "Xcode" || environment === "LocalTesting") {
        const tx = parseTransactionPayload(decoded.payload);
        if (!tx) return { ok: false, reason: "signature" };
        return policyResult(tx, checkTransactionPolicy(tx, config));
      }
    } catch {
      return { ok: false, reason: "signature" };
    }
  }
  try {
    payload = (await verifyAppleJws(compact, { roots: config.roots, now })).payload;
  } catch (error) {
    if (error instanceof JwsVerificationError) return { ok: false, reason: "signature" };
    throw error;
  }
  const tx = parseTransactionPayload(payload);
  if (!tx) return { ok: false, reason: "signature" };
  return policyResult(tx, checkTransactionPolicy(tx, config));
}

export const statusFromTransaction = (tx: TransactionInfo, now: number): EntitlementStatus =>
  tx.revocationDate !== undefined ? "revoked" : (tx.expiresDate ?? 0) > now ? "active" : "expired";

const clientIp = (request: Request) => addressKey(request.headers.get("cf-connecting-ip"));

export async function handleVerify(request: Request, env: Env, ctx: ExecutionContext, config: Config): Promise<Response> {
  const now = Date.now();
  if (!(await allow(env.RL_API_IP, clientIp(request), "RL_API_IP"))) return json({ error: "rate_limited", retryAfterSeconds: 60 }, 429, { "retry-after": "60" });
  let body: unknown;
  try {
    body = await readJsonBody(request, MAX_BODY_BYTES);
  } catch (error) {
    if (error instanceof BodyTooLarge) return json({ error: "invalid_request" }, 400);
    throw error;
  }
  if (!isRecord(body) || typeof body.signedTransaction !== "string" || typeof body.deviceId !== "string" || !HEX64.test(body.deviceId) ||
      body.signedTransaction.length === 0 || body.signedTransaction.length > MAX_JWS_CHARS) {
    return json({ error: "invalid_request" }, 400);
  }
  const deviceId = body.deviceId;
  if (!(await allow(env.RL_API_DEVICE, deviceId, "RL_API_DEVICE"))) return json({ error: "rate_limited", retryAfterSeconds: 60 }, 429, { "retry-after": "60" });
  if (config.roots.length === 0 && !(config.allowXcode && !config.isProduction)) {
    log("verify_unavailable", { reason: "no_apple_roots" });
    return json({ error: "unavailable" }, 503);
  }

  const verified = await verifyTransactionJws(body.signedTransaction, config, now);
  if (!verified.ok) {
    // A seat that is not the caller's own purchase is logged by kind only: no device, no transaction.
    log("verify_rejected", verified.reason === "not_purchased"
      ? { reason: verified.reason, ownership: verified.ownership }
      : { reason: verified.reason, device: fingerprint(deviceId) });
    return json({ error: "invalid_transaction", reason: verified.reason }, 401);
  }
  const tx = verified.tx;
  if (tx.environment === "Sandbox" && !(await allow(env.RL_API_SANDBOX, deviceId, "RL_API_SANDBOX"))) {
    return json({ error: "rate_limited", retryAfterSeconds: 60 }, 429, { "retry-after": "60" });
  }
  const id = await entitlementIdFor(env.ENTITLEMENT_HASH_KEY, tx.originalTransactionId);
  const environment = tx.environment === "LocalTesting" ? "Xcode" : tx.environment;

  try {
    const appTransactionHash = tx.appTransactionId ? await appTransactionHashFor(env.ENTITLEMENT_HASH_KEY, tx.appTransactionId) : undefined;
    if (appTransactionHash && (await consentStopped(env.DB, appTransactionHash))) {
      ctx.waitUntil(audit(env.DB, "verify_consent_stopped", { entitlementId: id }, now));
      return json({ entitled: false, reason: "consent_revoked", environment });
    }
    const existing = await getEntitlement(env.DB, id);
    // A notification may already know about a later renewal or a grace period; never move access backwards from a stale JWS.
    const expiresAt = Math.max(tx.expiresDate ?? 0, existing?.expires_at ?? 0);
    // A purchase made after a refund is a new, valid subscription even before Apple's SUBSCRIBED notice arrives.
    const supersedesRefund = existing?.revoked_at !== null && existing?.revoked_at !== undefined &&
      tx.revocationDate === undefined && (tx.purchaseDate ?? 0) > existing.revoked_at;
    const revokedAt = tx.revocationDate ?? (supersedesRefund ? null : existing?.revoked_at ?? null);
    let status = statusFromTransaction({ ...tx, expiresDate: expiresAt, revocationDate: revokedAt ?? undefined }, now);
    if (status === "expired" && existing && existing.status === "grace" && (existing.grace_until ?? 0) > now) status = "grace";
    await upsertEntitlement(env.DB, {
      id, productId: tx.productId, environment, status, expiresAt,
      graceUntil: existing?.grace_until ?? null, revokedAt, purchaseAt: tx.purchaseDate, appTransactionHash, source: "verify",
    }, now);
    // A refund may have committed after the read above. Use the row that actually survived the
    // conditional upsert before linking a device or issuing a token.
    const row = await getEntitlement(env.DB, id);
    if (!row) throw new Error("entitlement missing after upsert");
    if (!hasAccess(row, now)) {
      ctx.waitUntil(audit(env.DB, "verify_no_access", { entitlementId: id, detail: row.status }, now));
      const reason = row.consent_stopped_at ? "consent_revoked" : row.status === "revoked" ? "revoked" : "expired";
      return json({ entitled: false, reason, expiresAt: isoFromMs(row.expires_at), environment: row.environment });
    }
    // Sandbox purchases are free (D5): one device each keeps App Review and TestFlight working without opening a relay pool.
    const link = await linkDevice(env.DB, id, deviceId, now, row.environment === "Sandbox" ? 1 : config.maxDevices);
    if (link === "device_limit") {
      ctx.waitUntil(audit(env.DB, "verify_device_limit", { entitlementId: id }, now));
      return json({ entitled: false, reason: "device_limit", expiresAt: isoFromMs(row.expires_at), environment: row.environment });
    }
    const accessEnd = Math.max(row.expires_at, row.grace_until ?? 0);
    const tokenExpiresAt = Math.min(now + MAX_TOKEN_TTL_MS, accessEnd);
    const entitlementToken = await mintEntitlementToken(env.ENTITLEMENT_TOKEN_KEY, {
      v: 1, d: deviceId, s: id, x: Math.floor(tokenExpiresAt / 1000), n: environmentLetter(row.environment), e: config.environmentName,
    });
    ctx.waitUntil(audit(env.DB, "verify_ok", { entitlementId: id, detail: environment }, now));
    log("verify_ok", { environment: row.environment, status: row.status, device: fingerprint(deviceId), entitlement: fingerprint(id) });
    return json({
      entitled: true,
      expiresAt: isoFromMs(row.expires_at),
      environment: row.environment,
      productId: tx.productId,
      inGracePeriod: row.status === "grace",
      entitlementToken,
      tokenExpiresAt: isoFromMs(tokenExpiresAt),
    });
  } catch (error) {
    log("verify_storage_failed", { error: error instanceof Error ? error.message : String(error) });
    return json({ error: "unavailable" }, 503);
  }
}

export async function handleForget(request: Request, env: Env, config: Config): Promise<Response> {
  const now = Date.now();
  if (!(await allow(env.RL_API_IP, clientIp(request), "RL_API_IP"))) return json({ error: "rate_limited", retryAfterSeconds: 60 }, 429, { "retry-after": "60" });
  let body: unknown;
  try {
    body = await readJsonBody(request, MAX_BODY_BYTES);
  } catch (error) {
    if (error instanceof BodyTooLarge) return json({ error: "invalid_request" }, 400);
    throw error;
  }
  if (!isRecord(body) || typeof body.deviceId !== "string" || !HEX64.test(body.deviceId) || typeof body.entitlementToken !== "string") {
    return json({ error: "invalid_request" }, 400);
  }
  const payload = await verifyEntitlementToken(env.ENTITLEMENT_TOKEN_KEY, body.entitlementToken, now, config.environmentName);
  if (!payload || payload.d !== body.deviceId) return json({ error: "unauthorized" }, 401);
  try {
    for (let attempt = 0; attempt < 8; attempt += 1) {
      const row = await entitlementForDevice(env.DB, payload.s, payload.d);
      if (!row) return new Response(null, { status: 204 });
      // Revoke before unlinking so an RPC failure leaves a retryable device/room reference.
      // The conditional delete retries if another registration claims a different room meanwhile.
      if (row.device_room) {
        const rooms = env.ROOM as unknown as DurableObjectNamespace<RoomDO>;
        await rooms.get(rooms.idFromName(row.device_room)).revokeEntitlement(payload.s, payload.d);
      }
      if (await unlinkDeviceIfInRoom(env.DB, payload.s, payload.d, row.device_room)) {
        await audit(env.DB, "device_unlinked", { entitlementId: payload.s }, now);
        return new Response(null, { status: 204 });
      }
    }
  } catch (error) {
    logError("device_forget_failed", error, { entitlement: fingerprint(payload.s) });
    return json({ error: "unavailable" }, 503);
  }
  return json({ error: "unavailable" }, 503);
}
