import { decodeJwsUnverified, JwsVerificationError, verifyAppleJws } from "../apple/jws";
import type { Config } from "../config";
import { fingerprint, log } from "../log";
import { allow } from "../ratelimit";
import { BodyTooLarge, HEX64, isoFromMs, isRecord, json, readJsonBody } from "../util";
import { audit, entitlementIdFor, getEntitlement, hasAccess, isDeviceLinked, linkDevice, unlinkDevice, upsertEntitlement, type EntitlementStatus } from "./store";
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
  appAppleId?: number;
};

const optionalNumber = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : undefined);

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
    appAppleId: optionalNumber(payload.appAppleId),
  };
}

export type PolicyFailure = "wrong_app" | "wrong_product" | "environment_not_accepted" | "not_subscription";

export function checkTransactionPolicy(tx: TransactionInfo, config: Config): PolicyFailure | undefined {
  if (tx.bundleId !== config.bundleId) return "wrong_app";
  if (tx.environment === "Production" && config.appAppleId !== undefined && tx.appAppleId !== config.appAppleId) return "wrong_app";
  if (tx.environment === "Sandbox" && !config.acceptSandbox) return "environment_not_accepted";
  if ((tx.environment === "Xcode" || tx.environment === "LocalTesting") && !config.allowXcode) return "environment_not_accepted";
  if (!config.allowedProductIds.has(tx.productId)) return "wrong_product";
  if (tx.type !== "Auto-Renewable Subscription") return "not_subscription";
  return undefined;
}

export type SignatureFailure = "signature" | PolicyFailure;

/** Verifies a StoreKit / App Store JWS and applies the product policy. Xcode transactions are decoded unverified only when allowed. */
export async function verifyTransactionJws(compact: string, config: Config, now: number): Promise<{ ok: true; tx: TransactionInfo } | { ok: false; reason: SignatureFailure }> {
  if (typeof compact !== "string" || compact.length === 0 || compact.length > MAX_JWS_CHARS) return { ok: false, reason: "signature" };
  let payload: Record<string, unknown>;
  if (config.allowXcode && !config.isProduction) {
    try {
      const decoded = decodeJwsUnverified(compact);
      const environment = decoded.payload.environment;
      if (environment === "Xcode" || environment === "LocalTesting") {
        const tx = parseTransactionPayload(decoded.payload);
        if (!tx) return { ok: false, reason: "signature" };
        const policy = checkTransactionPolicy(tx, config);
        return policy ? { ok: false, reason: policy } : { ok: true, tx };
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
  const policy = checkTransactionPolicy(tx, config);
  return policy ? { ok: false, reason: policy } : { ok: true, tx };
}

export const statusFromTransaction = (tx: TransactionInfo, now: number): EntitlementStatus =>
  tx.revocationDate !== undefined ? "revoked" : (tx.expiresDate ?? 0) > now ? "active" : "expired";

function clientIp(request: Request): string {
  return request.headers.get("cf-connecting-ip") ?? "unknown";
}

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
    log("verify_rejected", { reason: verified.reason, device: fingerprint(deviceId) });
    return json({ error: "invalid_transaction", reason: verified.reason }, 401);
  }
  const tx = verified.tx;
  if (tx.environment === "Sandbox" && !(await allow(env.RL_API_SANDBOX, deviceId, "RL_API_SANDBOX"))) {
    return json({ error: "rate_limited", retryAfterSeconds: 60 }, 429, { "retry-after": "60" });
  }
  const id = await entitlementIdFor(env.ENTITLEMENT_HASH_KEY, tx.originalTransactionId);
  const environment = tx.environment === "LocalTesting" ? "Xcode" : tx.environment;

  try {
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
      graceUntil: existing?.grace_until ?? null, revokedAt, source: "verify",
    }, now);
    const row = { status, expires_at: expiresAt, grace_until: existing?.grace_until ?? null };
    if (!hasAccess(row, now)) {
      ctx.waitUntil(audit(env.DB, "verify_no_access", { entitlementId: id, detail: status }, now));
      return json({ entitled: false, reason: status === "revoked" ? "revoked" : "expired", expiresAt: isoFromMs(expiresAt), environment });
    }
    const link = await linkDevice(env.DB, id, deviceId, now, config.maxDevices);
    if (link === "device_limit") {
      ctx.waitUntil(audit(env.DB, "verify_device_limit", { entitlementId: id }, now));
      return json({ entitled: false, reason: "device_limit", expiresAt: isoFromMs(expiresAt), environment });
    }
    const accessEnd = Math.max(expiresAt, row.grace_until ?? 0);
    const tokenExpiresAt = Math.min(now + MAX_TOKEN_TTL_MS, accessEnd);
    const entitlementToken = await mintEntitlementToken(env.ENTITLEMENT_TOKEN_KEY, {
      v: 1, d: deviceId, s: id, x: Math.floor(tokenExpiresAt / 1000), n: environmentLetter(environment),
    });
    ctx.waitUntil(audit(env.DB, "verify_ok", { entitlementId: id, detail: environment }, now));
    log("verify_ok", { environment, status, device: fingerprint(deviceId), entitlement: fingerprint(id) });
    return json({
      entitled: true,
      expiresAt: isoFromMs(expiresAt),
      environment,
      productId: tx.productId,
      inGracePeriod: status === "grace",
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
  const payload = await verifyEntitlementToken(env.ENTITLEMENT_TOKEN_KEY, body.entitlementToken, now);
  if (!payload || payload.d !== body.deviceId) return json({ error: "unauthorized" }, 401);
  void config;
  try {
    if (!(await isDeviceLinked(env.DB, payload.s, payload.d))) return new Response(null, { status: 204 });
    await unlinkDevice(env.DB, payload.s, payload.d);
    await audit(env.DB, "device_unlinked", { entitlementId: payload.s }, now);
    return new Response(null, { status: 204 });
  } catch {
    return json({ error: "unavailable" }, 503);
  }
}
