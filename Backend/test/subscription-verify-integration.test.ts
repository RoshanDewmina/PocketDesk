import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { loadConfig } from "../src/config";
import { handleVerify } from "../src/entitlement/verify";
import { appTransactionHashFor, entitlementIdFor, getEntitlement, upsertEntitlement } from "../src/entitlement/store";
import { base64Encode, randomHex } from "../src/util";
import { parseChain, signCompactJws, transactionPayload, type TestChain } from "./helpers/apple-chain";
import { testEnv } from "./helpers/client";
import worker from "../src/index";

let chain: TestChain;
beforeAll(() => { chain = parseChain(testEnv.TEST_APPLE_CHAIN); });
afterEach(() => vi.restoreAllMocks());

async function verify(subscription: Record<string, unknown>, enabled = true, database = testEnv.DB) {
  const env = { ...testEnv, DB: database, SUBSCRIPTION_RECOVERY_ENABLED: enabled ? "1" : "0",
    APPLE_IAP_ISSUER_ID: "fixture", APPLE_IAP_KEY_ID: "fixture",
    APPLE_IAP_PRIVATE_KEY: `-----BEGIN PRIVATE KEY-----\n${base64Encode(chain.leafPrivatePkcs8)}\n-----END PRIVATE KEY-----` };
  const pending: Promise<unknown>[] = [];
  const ctx = { waitUntil: (promise: Promise<unknown>) => { pending.push(promise); } } as ExecutionContext;
  const request = new Request("https://farside.test/v1/entitlements/verify", { method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": randomHex(8) },
    body: JSON.stringify({ signedTransaction: await signCompactJws(subscription, chain), deviceId: randomHex() }) });
  const response = await handleVerify(request, env, ctx, loadConfig(env));
  await Promise.all(pending);
  return { response, body: await response.json() as Record<string, unknown> };
}

describe("subscription verify recovery integration", () => {
  it("minute cron invokes enabled history recovery and rollback makes no Apple request", async () => {
    const env = { ...testEnv, SUBSCRIPTION_RECOVERY_ENABLED: "1", APPLE_IAP_ISSUER_ID: "fixture", APPLE_IAP_KEY_ID: "fixture",
      APPLE_IAP_PRIVATE_KEY: `-----BEGIN PRIVATE KEY-----\n${base64Encode(chain.leafPrivatePkcs8)}\n-----END PRIVATE KEY-----` };
    const fetcher = vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({ hasMore: false, notificationHistory: [] }));
    const pending: Promise<unknown>[] = [];
    const ctx = { waitUntil: (promise: Promise<unknown>) => { pending.push(promise); } } as ExecutionContext;
    await worker.scheduled({ cron: "* * * * *" } as ScheduledController, env, ctx);
    await Promise.all(pending);
    expect(fetcher.mock.calls.filter(([url]) => String(url).includes("/notifications/history"))).toHaveLength(2);
    expect((await testEnv.DB.prepare("SELECT * FROM subscription_recovery_cursors").all()).results).toHaveLength(2);
    fetcher.mockClear();
    pending.length = 0;
    await worker.scheduled({ cron: "* * * * *" } as ScheduledController, { ...env, SUBSCRIPTION_RECOVERY_ENABLED: "0" }, ctx);
    await Promise.all(pending);
    expect(fetcher).not.toHaveBeenCalled();
  });
  it("recovers signed grace before minting a token and saves its Apple lookup identifier", async () => {
    const now = Date.now(), grace = now + 3600_000;
    const tx = transactionPayload({ originalTransactionId: `grace-${randomHex(6)}`, expiresDate: now - 1000 }, now);
    const signedTransactionInfo = await signCompactJws(tx, chain);
    const signedRenewalInfo = await signCompactJws({ originalTransactionId: tx.originalTransactionId,
      productId: tx.productId, environment: tx.environment, signedDate: now, gracePeriodExpiresDate: grace }, chain);
    vi.spyOn(globalThis, "fetch").mockImplementation(async input => Response.json(String(input).includes("/transactions/")
      ? { signedTransactionInfo }
      : { data: [{ lastTransactions: [{ signedTransactionInfo, signedRenewalInfo }] }] }));
    const { response, body } = await verify(tx);
    expect(response.status).toBe(200);
    expect(body).toMatchObject({ entitled: true, inGracePeriod: true, tokenExpiresAt: new Date(grace).toISOString() });
    const id = await entitlementIdFor(testEnv.ENTITLEMENT_HASH_KEY, String(tx.originalTransactionId));
    expect(await getEntitlement(testEnv.DB, id)).toMatchObject({ subscription_original_transaction_id: tx.originalTransactionId, grace_until: grace });
  });

  it("fails closed when enabled and Apple is unavailable", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(null, { status: 503 }));
    const tx = transactionPayload({ originalTransactionId: `unavailable-${randomHex(6)}` }, Date.now());
    const { response, body } = await verify(tx);
    expect(response.status).toBe(503);
    expect(body).toEqual({ error: "unavailable" });
    expect(await getEntitlement(testEnv.DB, await entitlementIdFor(testEnv.ENTITLEMENT_HASH_KEY, String(tx.originalTransactionId)))).toBeNull();
  });

  it("rollback grants the original signed active transaction without Apple calls", async () => {
    const fetcher = vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("must not call Apple"));
    const tx = transactionPayload({ originalTransactionId: `disabled-${randomHex(6)}` }, Date.now());
    const { response, body } = await verify(tx, false);
    expect(response.status).toBe(200);
    expect(body.entitled).toBe(true);
    expect(fetcher).not.toHaveBeenCalled();
    expect(await getEntitlement(testEnv.DB, await entitlementIdFor(testEnv.ENTITLEMENT_HASH_KEY, String(tx.originalTransactionId))))
      .toMatchObject({ subscription_original_transaction_id: null });
  });

  it("retains consent denial when Apple's refreshed payload omits the input app transaction", async () => {
    const now = Date.now();
    const appTransactionId = `app-${randomHex(6)}`;
    const tx = transactionPayload({ originalTransactionId: `consent-${randomHex(6)}`, appTransactionId }, now);
    const current = { ...tx };
    delete current.appTransactionId;
    const signedTransactionInfo = await signCompactJws(current, chain);
    const signedRenewalInfo = await signCompactJws({ originalTransactionId: tx.originalTransactionId,
      productId: tx.productId, environment: tx.environment, signedDate: now }, chain);
    await testEnv.DB.prepare("INSERT INTO consent_stops VALUES (?1,'Production',?2)")
      .bind(await appTransactionHashFor(testEnv.ENTITLEMENT_HASH_KEY, appTransactionId), now).run();
    vi.spyOn(globalThis, "fetch").mockImplementation(async input => Response.json(String(input).includes("/transactions/")
      ? { signedTransactionInfo } : { data: [{ lastTransactions: [{ signedTransactionInfo, signedRenewalInfo }] }] }));
    const { body } = await verify(tx);
    expect(body).toMatchObject({ entitled: false, reason: "consent_revoked" });
  });

  it("does not overwrite a newer expiry arriving after the recovered grace row is read", async () => {
    const now = Date.now();
    const tx = transactionPayload({ originalTransactionId: `race-${randomHex(6)}`, expiresDate: now - 1000 }, now);
    const id = await entitlementIdFor(testEnv.ENTITLEMENT_HASH_KEY, String(tx.originalTransactionId));
    const signedTransactionInfo = await signCompactJws(tx, chain);
    const signedRenewalInfo = await signCompactJws({ originalTransactionId: tx.originalTransactionId,
      productId: tx.productId, environment: tx.environment, signedDate: now, gracePeriodExpiresDate: now + 3600_000 }, chain);
    vi.spyOn(globalThis, "fetch").mockImplementation(async input => Response.json(String(input).includes("/transactions/")
      ? { signedTransactionInfo } : { data: [{ lastTransactions: [{ signedTransactionInfo, signedRenewalInfo }] }] }));
    let injected = false;
    function wrap(statement: D1PreparedStatement): D1PreparedStatement {
      return new Proxy(statement, { get(target, key) {
        if (key === "bind") return (...values: unknown[]) => wrap(target.bind(...values));
        if (key === "first") return async (...values: unknown[]) => {
          const row = values.length ? await target.first(String(values[0])) : await target.first();
          if (!injected) {
            injected = true;
            await upsertEntitlement(testEnv.DB, { id, productId: String(tx.productId), environment: "Production", kind: "subscription",
              status: "expired", expiresAt: Number(tx.expiresDate), graceUntil: null, purchaseAt: Number(tx.purchaseDate),
              notificationSignedAt: now + 1000, source: "notification" }, now);
          }
          return row;
        };
        const value = Reflect.get(target, key);
        return typeof value === "function" ? value.bind(target) : value;
      } });
    }
    const db = new Proxy(testEnv.DB, { get(target, key) {
      if (key === "prepare") return (sql: string) => sql === "SELECT * FROM entitlements WHERE id = ?1" ? wrap(target.prepare(sql)) : target.prepare(sql);
      const value = Reflect.get(target, key);
      return typeof value === "function" ? value.bind(target) : value;
    } });
    const { body } = await verify(tx, true, db);
    expect(injected).toBe(true);
    expect(body.entitled).toBe(false);
    expect(await getEntitlement(testEnv.DB, id)).toMatchObject({ status: "expired", grace_until: null });
  });
});
