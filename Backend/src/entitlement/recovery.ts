import { appleApiConfigFromEnv, getAllSubscriptionStatuses, getNotificationHistory, getTransactionInfo, type AppleApiConfig } from "../apple/server-api";
import { APPLE_JWS_CLOCK_SKEW_MS, verifyAppleJws } from "../apple/jws";
import type { Config } from "../config";
import { log } from "../log";
import type { RoomDO } from "../room";
import { isRecord } from "../util";
import { applyNotification } from "./notifications";
import { devicesForEntitlement, entitlementIdFor, getEntitlement, upsertEntitlement, type EntitlementRow } from "./store";
import { statusFromTransaction, verifyTransactionJws, type TransactionInfo } from "./verify";

const DAY = 86400000;
const OVERLAP = 5 * 60_000;
const RUN_BUDGET = 45_000;
const MAX_STATUS_BATCH = 4;
const MAX_REVOCATION_BATCH = 20;
type AppleEnvironment = "Production" | "Sandbox";
type Cursor = { environment: AppleEnvironment; start_at: number; end_at: number; pagination_token: string | null; completed_at: number | null };
export type RecoveryDependencies = { api?: (environment: AppleEnvironment) => AppleApiConfig | undefined };
export type SubscriptionSnapshot = { tx: TransactionInfo; graceUntil: number | null; signedAt: number };
export const subscriptionRecoveryEnabled = (env: Env): boolean => (env as Env & { SUBSCRIPTION_RECOVERY_ENABLED?: string }).SUBSCRIPTION_RECOVERY_ENABLED === "1";

function signedTime(value: unknown, now: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0 || value > now + APPLE_JWS_CLOCK_SKEW_MS) throw new Error("subscription signed date invalid");
  return value;
}

async function verifiedSubscription(compact: unknown, config: Config, now: number, otid: string, environment: AppleEnvironment): Promise<TransactionInfo> {
  if (typeof compact !== "string") throw new Error("subscription transaction missing");
  const verified = await verifyTransactionJws(compact, config, now);
  if (!verified.ok || verified.tx.type !== "Auto-Renewable Subscription" || verified.tx.originalTransactionId !== otid || verified.tx.environment !== environment ||
      typeof verified.tx.expiresDate !== "number" || !Number.isSafeInteger(verified.tx.expiresDate) || verified.tx.expiresDate <= 0 ||
      typeof verified.tx.purchaseDate !== "number" || !Number.isSafeInteger(verified.tx.purchaseDate) || verified.tx.purchaseDate <= 0) throw new Error("subscription identity invalid");
  signedTime(verified.tx.signedDate, now);
  return verified.tx;
}

/** An HTTP status or envelope field grants nothing. Only signed, matching transaction and renewal data can grant grace. */
async function subscriptionStatus(api: AppleApiConfig, config: Config, otid: string, now: number): Promise<SubscriptionSnapshot> {
  const response = await getAllSubscriptionStatuses(api, otid, now);
  if (response.status !== 200 || !isRecord(response.body) || !Array.isArray(response.body.data) || response.body.data.length > 32) throw new Error("subscription status unavailable");
  let latest: SubscriptionSnapshot | undefined;
  let itemCount = 0;
  for (const group of response.body.data) {
    if (!isRecord(group) || !Array.isArray(group.lastTransactions)) throw new Error("subscription status malformed");
    for (const item of group.lastTransactions) {
      if (++itemCount > 64 || !isRecord(item) || typeof item.signedTransactionInfo !== "string" || typeof item.signedRenewalInfo !== "string") throw new Error("subscription status malformed");
      // Apple may include other subscriptions for this customer. Verify them before selecting the requested lineage.
      const signed = (await verifyAppleJws(item.signedTransactionInfo, { roots: config.roots, now, maxChars: 16 * 1024 })).payload;
      if (signed.bundleId !== config.bundleId || signed.environment !== api.environment) throw new Error("subscription status app invalid");
      if (signed.originalTransactionId !== otid) continue;
      const tx = await verifiedSubscription(item.signedTransactionInfo, config, now, otid, api.environment);
      const renewal = (await verifyAppleJws(item.signedRenewalInfo, { roots: config.roots, now, maxChars: 16 * 1024 })).payload;
      if (renewal.originalTransactionId !== otid || renewal.environment !== api.environment || renewal.productId !== tx.productId) throw new Error("subscription renewal identity invalid");
      const renewalSigned = signedTime(renewal.signedDate, now);
      const signedAt = Math.min(signedTime(tx.signedDate, now), renewalSigned);
      const grace = renewal.gracePeriodExpiresDate;
      if (grace !== undefined && (typeof grace !== "number" || !Number.isSafeInteger(grace) || grace <= 0)) throw new Error("subscription grace invalid");
      const candidate = { tx, graceUntil: typeof grace === "number" && grace > now && tx.revocationDate === undefined ? grace : null, signedAt };
      if (!latest || (tx.purchaseDate ?? 0) > (latest.tx.purchaseDate ?? 0) ||
        (tx.purchaseDate === latest.tx.purchaseDate && (signedAt > latest.signedAt || (signedAt === latest.signedAt && tx.revocationDate !== undefined)))) latest = candidate;
    }
  }
  if (!latest) throw new Error("subscription status lineage missing");
  return latest;
}

/** Caller has already verified the input. Enabled subscription verification refreshes both the exact transaction and latest subscription state. */
export async function refreshSubscriptionFromApple(env: Env, config: Config, input: TransactionInfo, now: number, suppliedApi?: AppleApiConfig): Promise<SubscriptionSnapshot> {
  if (!subscriptionRecoveryEnabled(env)) return { tx: input, graceUntil: null, signedAt: input.signedDate ?? 0 };
  if (input.environment !== "Production" && input.environment !== "Sandbox") return { tx: input, graceUntil: null, signedAt: input.signedDate ?? 0 };
  const api = suppliedApi ?? appleApiConfigFromEnv(env, input.environment);
  if (!api || api.environment !== input.environment || api.bundleId !== config.bundleId) throw new Error("subscription API unavailable");
  const response = await getTransactionInfo(api, input.transactionId, now);
  if (response.status !== 200 || !isRecord(response.body)) throw new Error("subscription transaction unavailable");
  const tx = await verifiedSubscription(response.body.signedTransactionInfo, config, now, input.originalTransactionId, input.environment);
  if (tx.transactionId !== input.transactionId || tx.productId !== input.productId || tx.bundleId !== input.bundleId) throw new Error("subscription transaction mismatch");
  if (input.appTransactionId && tx.appTransactionId && input.appTransactionId !== tx.appTransactionId) throw new Error("subscription app transaction mismatch");
  const current = await subscriptionStatus(api, config, input.originalTransactionId, now);
  if (input.appTransactionId && current.tx.appTransactionId && input.appTransactionId !== current.tx.appTransactionId) throw new Error("subscription app transaction mismatch");
  // A refunded exact transaction cannot be laundered through another unrevoked status for the same purchase.
  if (tx.revocationDate !== undefined && (current.tx.purchaseDate ?? 0) <= (tx.purchaseDate ?? 0)) return { tx, graceUntil: null, signedAt: signedTime(tx.signedDate, now) };
  return current;
}

async function recoverHistory(env: Env, config: Config, api: AppleApiConfig, now: number, owner: string, deadline: number): Promise<number> {
  let cursor = await env.DB.prepare("SELECT * FROM subscription_recovery_cursors WHERE environment=?1").bind(api.environment).first<Cursor>();
  const oldest = now - (api.environment === "Sandbox" ? 30 : 180) * DAY + 60_000;
  if (!cursor) {
    // A full retention-edge bootstrap would age out during pagination. Leave one day to finish catchup.
    await env.DB.prepare("INSERT OR IGNORE INTO subscription_recovery_cursors (environment,start_at,end_at) VALUES (?1,?2,?3)").bind(api.environment, now - (api.environment === "Sandbox" ? 29 : 179) * DAY, now).run();
    cursor = await env.DB.prepare("SELECT * FROM subscription_recovery_cursors WHERE environment=?1").bind(api.environment).first<Cursor>();
  }
  if (!cursor) throw new Error("recovery cursor unavailable");
  if (cursor.completed_at !== null) {
    const start = Math.max(oldest, cursor.end_at - OVERLAP);
    if (now <= start) return 0;
    await env.DB.prepare("UPDATE subscription_recovery_cursors SET start_at=?2,end_at=?3,pagination_token=NULL,completed_at=NULL WHERE environment=?1").bind(api.environment, start, now).run();
    cursor = { ...cursor, start_at: start, end_at: now, pagination_token: null, completed_at: null };
  }
  // An unfinished cursor is never silently reset. If downtime exceeds Apple's retention, operator reconciliation is required.
  if (cursor.start_at < oldest - 60_000) throw new Error("recovery cursor outside Apple retention");
  const response = await getNotificationHistory(api, { startDate: cursor.start_at, endDate: cursor.end_at, paginationToken: cursor.pagination_token }, now);
  if (response.status !== 200 || !isRecord(response.body) || typeof response.body.hasMore !== "boolean" || !Array.isArray(response.body.notificationHistory) || response.body.notificationHistory.length > 20) throw new Error("notification history unavailable");
  const token = response.body.hasMore ? response.body.paginationToken : null;
  if (response.body.hasMore && (typeof token !== "string" || token.length === 0 || token.length > 4096 || token === cursor.pagination_token)) throw new Error("notification history cursor invalid");
  for (const item of response.body.notificationHistory) {
    if (Date.now() >= deadline) throw new Error("notification replay deadline");
    if (!isRecord(item) || typeof item.signedPayload !== "string") throw new Error("notification history item invalid");
    const decoded = (await verifyAppleJws(item.signedPayload, { roots: config.roots, now, maxChars: 64 * 1024 })).payload;
    signedTime(decoded.signedDate, now);
    const data = isRecord(decoded.data) ? decoded.data : isRecord(decoded.appData) ? decoded.appData : undefined;
    // TEST has no purchase identity. Every purchase event must carry signed app metadata, including its source environment.
    if (decoded.notificationType !== "TEST" && (!data || data.environment !== api.environment || data.bundleId !== config.bundleId ||
      (api.environment === "Production" && (config.appAppleId === undefined || data.appAppleId !== config.appAppleId)))) throw new Error("notification history identity invalid");
    if (typeof decoded.notificationUUID !== "string" || decoded.notificationUUID.length === 0 || decoded.notificationUUID.length > 64) throw new Error("notification history UUID invalid");
    if (data && typeof data.signedTransactionInfo === "string") {
      const tx = (await verifyAppleJws(data.signedTransactionInfo, { roots: config.roots, now, maxChars: 16 * 1024 })).payload;
      if (tx.bundleId !== config.bundleId || tx.environment !== api.environment) throw new Error("notification transaction identity invalid");
      if (typeof data.signedRenewalInfo === "string") {
        const renewal = (await verifyAppleJws(data.signedRenewalInfo, { roots: config.roots, now, maxChars: 16 * 1024 })).payload;
        if (renewal.originalTransactionId !== tx.originalTransactionId || renewal.environment !== tx.environment || renewal.productId !== tx.productId) throw new Error("notification renewal identity invalid");
      }
    }
    await applyNotification(env, config, decoded, now, { deferRevocationPush: true });
  }
  // Page side effects precede cursor advancement. A failed page replays its prefix safely through UUID and signed ordering.
  const result = await env.DB.prepare(`UPDATE subscription_recovery_cursors SET pagination_token=?2,completed_at=?3 WHERE environment=?1
    AND EXISTS(SELECT 1 FROM subscription_recovery_lock WHERE id=1 AND owner=?4 AND lease_until>?5)`)
    .bind(api.environment, token, response.body.hasMore ? null : now, owner, Date.now()).run();
  if (result.meta.changes !== 1) throw new Error("recovery lease lost");
  return response.body.notificationHistory.length;
}

function boundedRpc(promise: Promise<unknown>, timeout: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("revocation RPC deadline")), timeout);
    promise.then(() => { clearTimeout(timer); resolve(); }, error => { clearTimeout(timer); reject(error); });
  });
}

async function drainRevocations(env: Env, attempted: Set<string>, deadline: number): Promise<number> {
  const queued = (await env.DB.prepare("SELECT entitlement_id,queued_at FROM subscription_recovery_revocations ORDER BY COALESCE(last_attempt_at,0),queued_at,entitlement_id LIMIT ?1").bind(MAX_REVOCATION_BATCH + attempted.size).all<{ entitlement_id: string; queued_at: number }>()).results;
  let delivered = 0;
  const rooms = env.ROOM as unknown as DurableObjectNamespace<RoomDO>;
  for (const item of queued) {
    if (attempted.has(item.entitlement_id)) continue;
    if (Date.now() >= deadline || attempted.size >= MAX_REVOCATION_BATCH) break;
    attempted.add(item.entitlement_id);
    await env.DB.prepare("UPDATE subscription_recovery_revocations SET last_attempt_at=?3 WHERE entitlement_id=?1 AND queued_at=?2").bind(item.entitlement_id, item.queued_at, Date.now()).run();
    try {
      const row = await getEntitlement(env.DB, item.entitlement_id);
      // A later legitimate purchase may have cleared the tombstone while delivery was pending.
      if (row?.status === "revoked") {
        for (const device of await devicesForEntitlement(env.DB, item.entitlement_id)) {
          if (Date.now() >= deadline) throw new Error("revocation run deadline");
          if (device.last_room) await boundedRpc(rooms.get(rooms.idFromName(device.last_room)).revokeEntitlement(item.entitlement_id, device.device_id, true), Math.min(5000, deadline - Date.now()));
        }
      }
      await env.DB.prepare("DELETE FROM subscription_recovery_revocations WHERE entitlement_id=?1 AND queued_at=?2").bind(item.entitlement_id, item.queued_at).run();
      delivered++;
    } catch { log("subscription_recovery_push_failed"); }
  }
  return delivered;
}

/** Minute cron entry point. Disabled is exactly no recovery. One page per environment, four status lookups, persistent RPC retry, exclusive lease. */
export async function recoverSubscriptions(env: Env, config: Config, now = Date.now(), dependencies: RecoveryDependencies = {}): Promise<{ enabled: boolean; busy?: boolean; notifications: number; statuses: number; revocations: number; failures: number }> {
  const result = { enabled: subscriptionRecoveryEnabled(env), notifications: 0, statuses: 0, revocations: 0, failures: 0 };
  if (!result.enabled) return result;
  if (config.roots.length === 0) return { ...result, failures: 1 };
  const owner = crypto.randomUUID();
  const acquired = await env.DB.prepare(`INSERT INTO subscription_recovery_lock (id,owner,lease_until) VALUES(1,?1,?2)
    ON CONFLICT(id) DO UPDATE SET owner=excluded.owner,lease_until=excluded.lease_until WHERE subscription_recovery_lock.lease_until<=?3`)
    .bind(owner, Date.now() + 5 * 60_000, Date.now()).run();
  if (acquired.meta.changes === 0) return { ...result, busy: true };
  const deadline = Date.now() + RUN_BUDGET;
  const attempted = new Set<string>();
  const factory = dependencies.api ?? ((environment: AppleEnvironment) => appleApiConfigFromEnv(env, environment));
  try {
    for (const environment of ["Production", ...(config.acceptSandbox ? ["Sandbox"] : [])] as AppleEnvironment[]) {
      if (Date.now() > deadline) break;
      const api = factory(environment);
      if (!api || api.environment !== environment || api.bundleId !== config.bundleId) { result.failures++; continue; }
      try { result.notifications += await recoverHistory(env, config, api, now, owner, deadline); }
      catch { result.failures++; log("subscription_recovery_history_failed", { environment }); }
    }
    // Refund delivery takes priority over status polling; failed deliveries remain durable for the next tick.
    result.revocations += await drainRevocations(env, attempted, deadline);
    const rows = (await env.DB.prepare(`SELECT * FROM entitlements WHERE kind='subscription' AND subscription_original_transaction_id IS NOT NULL
      AND environment IN ('Production','Sandbox') AND consent_stopped_at IS NULL AND status<>'revoked'
      AND MAX(expires_at,COALESCE(grace_until,0))>?1
      ORDER BY COALESCE(last_recovery_attempt_at,0),id LIMIT ?2`).bind(now - 90 * DAY, MAX_STATUS_BATCH).all<EntitlementRow>()).results;
    for (const row of rows) {
      if (Date.now() > deadline) break;
      // A failed provider/customer must not starve every later row in the bounded round-robin.
      await env.DB.prepare("UPDATE entitlements SET last_recovery_attempt_at=?2 WHERE id=?1").bind(row.id, now).run();
      try {
        if (row.environment === "Sandbox" && !config.acceptSandbox) continue;
        const api = factory(row.environment as AppleEnvironment);
        if (!api || api.environment !== row.environment || api.bundleId !== config.bundleId) throw new Error("subscription API unavailable");
        const current = await subscriptionStatus(api, config, row.subscription_original_transaction_id!, now);
        if ((await entitlementIdFor(env.ENTITLEMENT_HASH_KEY, current.tx.originalTransactionId)) !== row.id) throw new Error("subscription hash mismatch");
        const status = current.tx.revocationDate !== undefined ? "revoked" : current.graceUntil !== null ? "grace" : statusFromTransaction(current.tx, now);
        await upsertEntitlement(env.DB, { id: row.id, productId: current.tx.productId, environment: current.tx.environment, kind: "subscription", status,
          expiresAt: current.tx.expiresDate!, graceUntil: current.graceUntil, revokedAt: current.tx.revocationDate, purchaseAt: current.tx.purchaseDate,
          notificationSignedAt: current.signedAt, originalTransactionId: current.tx.originalTransactionId, source: "recheck" }, now);
        result.statuses++;
      } catch { result.failures++; log("subscription_recovery_status_failed", { environment: row.environment }); }
    }
    result.revocations += await drainRevocations(env, attempted, deadline);
    log("subscription_recovery", result);
    return result;
  } finally {
    await env.DB.prepare("DELETE FROM subscription_recovery_lock WHERE id=1 AND owner=?1").bind(owner).run();
  }
}
