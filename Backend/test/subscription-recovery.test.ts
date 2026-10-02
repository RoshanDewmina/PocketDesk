import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { loadConfig } from "../src/config";
import { getAllSubscriptionStatuses, getNotificationHistory, type AppleApiConfig } from "../src/apple/server-api";
import { applyNotification } from "../src/entitlement/notifications";
import { recoverSubscriptions, refreshSubscriptionFromApple } from "../src/entitlement/recovery";
import { entitlementIdFor, getEntitlement, upsertEntitlement } from "../src/entitlement/store";
import { base64Encode, randomHex } from "../src/util";
import { parseChain, signCompactJws, transactionPayload, type TestChain } from "./helpers/apple-chain";
import { testEnv } from "./helpers/client";
let chain: TestChain;
const now = Date.now(), day = 86400000, config = loadConfig(testEnv);
let api: AppleApiConfig;
beforeAll(() => { chain = parseChain(testEnv.TEST_APPLE_CHAIN); api = { issuerId: "fixture", keyId: "fixture", privateKeyPem: `-----BEGIN PRIVATE KEY-----\n${base64Encode(chain.leafPrivatePkcs8)}\n-----END PRIVATE KEY-----`, bundleId: config.bundleId, environment: "Production" }; });
beforeEach(async () => { await testEnv.DB.batch([testEnv.DB.prepare("DELETE FROM subscription_recovery_cursors"), testEnv.DB.prepare("DELETE FROM subscription_recovery_lock"), testEnv.DB.prepare("DELETE FROM subscription_recovery_revocations"), testEnv.DB.prepare("DELETE FROM entitlement_devices"), testEnv.DB.prepare("DELETE FROM entitlements")]); });
const enabled = () => ({ ...testEnv, SUBSCRIPTION_RECOVERY_ENABLED: "1" });
const provider = (fetcher: typeof fetch) => ({ api: (environment: "Production" | "Sandbox") => ({ ...api, environment, fetch: fetcher }) });
const response = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });
async function seed(otid: string, extra: Record<string, unknown> = {}) { const tx = transactionPayload({ originalTransactionId: otid, transactionId: otid, ...extra }, now); const id = await entitlementIdFor(testEnv.ENTITLEMENT_HASH_KEY, otid); await upsertEntitlement(testEnv.DB, { id, productId: String(tx.productId), environment: "Production", status: "active", expiresAt: Number(tx.expiresDate), purchaseAt: Number(tx.purchaseDate), originalTransactionId: otid, source: "verify" }, now); return { tx, id }; }
async function notice(tx: Record<string, unknown>) { return signCompactJws({ notificationType: "REFUND", notificationUUID: crypto.randomUUID(), signedDate: now, version: "2.0", data: { bundleId: config.bundleId, appAppleId: config.appAppleId, environment: "Production", signedTransactionInfo: await signCompactJws(tx, chain), signedRenewalInfo: await signCompactJws({ originalTransactionId: tx.originalTransactionId, productId: tx.productId, environment: "Production", signedDate: now }, chain) } }, chain); }
async function statuses(tx: Record<string, unknown>, renewal: Record<string, unknown> = {}) { return { bundleId: "untrusted", data: [{ lastTransactions: [{ status: 4, originalTransactionId: "untrusted", signedTransactionInfo: await signCompactJws(tx, chain), signedRenewalInfo: await signCompactJws({ originalTransactionId: tx.originalTransactionId, productId: tx.productId, environment: tx.environment, signedDate: now, ...renewal }, chain) }] }] }; }
describe("subscription recovery", () => {
    it("disabled does no database/provider work", async () => { const factory = vi.fn(); expect(await recoverSubscriptions({ ...testEnv, SUBSCRIPTION_RECOVERY_ENABLED: "0" }, config, now, { api: factory })).toMatchObject({ enabled: false }); expect(factory).not.toHaveBeenCalled(); expect((await testEnv.DB.prepare("SELECT * FROM subscription_recovery_cursors").all()).results).toEqual([]); });
    it("replays missed refund, pushes active room and retains durable page on provider failure", async () => {
        const { tx, id } = await seed(`refund-${randomHex(6)}`);
        const device = randomHex();
        await testEnv.DB.prepare("INSERT INTO entitlement_devices (entitlement_id,device_id,first_seen,last_seen,last_room) VALUES (?1,?2,?3,?3,?4)").bind(id, device, now, randomHex()).run();
        const signed = await notice({ ...tx, revocationDate: now - 100 });
        const fetcher = vi.fn(async (input: RequestInfo | URL) => {
            const url = String(input);
            if (url.includes("sandbox"))
                return response({ hasMore: false, notificationHistory: [] });
            if (url.includes("paginationToken"))
                return response({}, 503);
            if (url.includes("/history"))
                return response({ hasMore: true, paginationToken: "page-2", notificationHistory: [{ signedPayload: signed }] });
            return response({}, 503);
        }) as typeof fetch & ReturnType<typeof vi.fn>;
        const revoke = vi.fn(async () => { });
        const env = { ...enabled(), ROOM: { idFromName: (x: string) => x, get: () => ({ revokeEntitlement: revoke }) } } as unknown as Env;
        await recoverSubscriptions(env, config, now, provider(fetcher));
        expect((await getEntitlement(testEnv.DB, id))?.status).toBe("revoked");
        expect(revoke).toHaveBeenCalledWith(id, device, true);
        const cursor = await testEnv.DB.prepare("SELECT * FROM subscription_recovery_cursors WHERE environment='Production'").first();
        expect(cursor).toMatchObject({ pagination_token: "page-2" });
        await recoverSubscriptions(env, config, now + 60000, provider(fetcher));
        expect(fetcher.mock.calls.some(([url]) => String(url).includes("paginationToken=page-2"))).toBe(true);
        expect(await testEnv.DB.prepare("SELECT * FROM subscription_recovery_cursors WHERE environment='Production'").first()).toEqual(cursor);
    });
    it("does not advance invalid JWS page and retries RPC delivery", async () => { const { tx, id } = await seed(`retry-${randomHex(6)}`); await upsertEntitlement(testEnv.DB, { id, productId: String(tx.productId), environment: "Production", status: "revoked", expiresAt: now + day, purchaseAt: Number(tx.purchaseDate), revokedAt: now, source: "notification", notificationSignedAt: now }, now); const device = randomHex(); await testEnv.DB.prepare("INSERT INTO entitlement_devices (entitlement_id,device_id,first_seen,last_seen,last_room) VALUES (?1,?2,?3,?3,?4)").bind(id, device, now, randomHex()).run(); const revoke = vi.fn().mockRejectedValueOnce(new Error("fixture outage")).mockResolvedValue(undefined); const env = { ...enabled(), ROOM: { idFromName: (x: string) => x, get: () => ({ revokeEntitlement: revoke }) } } as unknown as Env; const fetcher = vi.fn(async () => response({ hasMore: false, notificationHistory: [{ signedPayload: "bad" }] })) as typeof fetch & ReturnType<typeof vi.fn>; await recoverSubscriptions(env, config, now, provider(fetcher)); expect(await testEnv.DB.prepare("SELECT * FROM subscription_recovery_revocations WHERE entitlement_id=?1").bind(id).first()).not.toBeNull(); expect(await testEnv.DB.prepare("SELECT * FROM subscription_recovery_cursors WHERE environment='Production'").first()).toMatchObject({ pagination_token: null }); await recoverSubscriptions(env, config, now + 60000, provider(fetcher)); expect(await testEnv.DB.prepare("SELECT * FROM subscription_recovery_revocations WHERE entitlement_id=?1").bind(id).first()).toBeNull(); });
    it("restores signed grace, ignores unsigned HTTP identity and preserves refund", async () => { const { tx, id } = await seed(`grace-${randomHex(6)}`, { expiresDate: now - 1000 }); const body = await statuses(tx, { gracePeriodExpiresDate: now + day, isInBillingRetryPeriod: true }); const fetcher = vi.fn(async (input: RequestInfo | URL) => String(input).includes("/history") ? response({ hasMore: false, notificationHistory: [] }) : response(body)) as typeof fetch & ReturnType<typeof vi.fn>; await recoverSubscriptions(enabled(), config, now, provider(fetcher)); expect(await getEntitlement(testEnv.DB, id)).toMatchObject({ status: "grace", grace_until: now + day }); await upsertEntitlement(testEnv.DB, { id, productId: String(tx.productId), environment: "Production", status: "revoked", expiresAt: now - 1000, purchaseAt: Number(tx.purchaseDate), revokedAt: now, source: "notification", notificationSignedAt: now }, now); await recoverSubscriptions(enabled(), config, now + 60000, provider(fetcher)); expect(await getEntitlement(testEnv.DB, id)).toMatchObject({ status: "revoked", revoked_at: now }); });
    it("rejects signed identity mismatches and invalid signatures without granting", async () => {
        const { tx, id } = await seed(`identity-${randomHex(6)}`, { expiresDate: now - 1000 });
        for (const body of [await statuses({ ...tx, originalTransactionId: "another" }), await statuses(tx, { environment: "Sandbox" }), await statuses(tx, { productId: "another" }), { data: [{ lastTransactions: [{ signedTransactionInfo: "bad", signedRenewalInfo: "bad" }] }] }]) {
            const fetcher = vi.fn(async (input: RequestInfo | URL) => String(input).includes("/history") ? response({ hasMore: false, notificationHistory: [] }) : response(body)) as typeof fetch & ReturnType<typeof vi.fn>;
            await recoverSubscriptions(enabled(), config, now, provider(fetcher));
            expect((await getEntitlement(testEnv.DB, id))?.status).toBe("active");
            expect((await getEntitlement(testEnv.DB, id))?.grace_until).toBeNull();
        }
    });
    it("orders status recovery against newer notification", async () => { const { tx, id } = await seed(`order-${randomHex(6)}`, { expiresDate: now - 1000 }); await upsertEntitlement(testEnv.DB, { id, productId: String(tx.productId), environment: "Production", status: "expired", expiresAt: now - 1000, purchaseAt: Number(tx.purchaseDate), notificationSignedAt: now + 1000, source: "notification" }, now); const body = await statuses(tx, { gracePeriodExpiresDate: now + day }); const fetcher = vi.fn(async (input: RequestInfo | URL) => String(input).includes("/history") ? response({ hasMore: false, notificationHistory: [] }) : response(body)) as typeof fetch & ReturnType<typeof vi.fn>; await recoverSubscriptions(enabled(), config, now + 2000, provider(fetcher)); expect((await getEntitlement(testEnv.DB, id))?.status).toBe("expired"); });
    it("refreshes exact verify transaction, restores grace, fails closed on HTTP/signature/identity failure", async () => { const tx = transactionPayload({ originalTransactionId: `verify-${randomHex(6)}`, expiresDate: now - 1000 }, now); const body = await statuses(tx, { gracePeriodExpiresDate: now + day }); const fetcher = vi.fn(async (input: RequestInfo | URL) => String(input).includes("/transactions/") ? response({ signedTransactionInfo: await signCompactJws(tx, chain) }) : response(body)) as typeof fetch & ReturnType<typeof vi.fn>; expect((await refreshSubscriptionFromApple(enabled(), config, tx as never, now, { ...api, fetch: fetcher })).graceUntil).toBe(now + day); await expect(refreshSubscriptionFromApple(enabled(), config, tx as never, now, { ...api, fetch: async () => response({}, 503) })).rejects.toThrow(); await expect(refreshSubscriptionFromApple(enabled(), config, tx as never, now, { ...api, fetch: async () => response({ signedTransactionInfo: await signCompactJws({ ...tx, transactionId: "different" }, chain) }) })).rejects.toThrow(); });
    it("preserves a three-page bootstrap window across minute ticks and refuses overlapping cron", async () => {
        const pageTokens: (string | null)[] = [];
        const windows: unknown[] = [];
        const fetcher = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
            const url = new URL(String(input));
            if (url.hostname.includes("sandbox"))
                return response({ hasMore: false, notificationHistory: [] });
            const token = url.searchParams.get("paginationToken");
            pageTokens.push(token);
            windows.push(JSON.parse(String(init?.body)));
            return response(token === null ? { hasMore: true, paginationToken: "two", notificationHistory: [] } : token === "two" ? { hasMore: true, paginationToken: "three", notificationHistory: [] } : { hasMore: false, notificationHistory: [] });
        }) as typeof fetch & ReturnType<typeof vi.fn>;
        for (let minute = 0; minute < 3; minute++)
            await recoverSubscriptions(enabled(), config, now + minute * 60000, provider(fetcher));
        expect(pageTokens).toEqual([null, "two", "three"]);
        expect(windows[1]).toEqual(windows[0]);
        expect(windows[2]).toEqual(windows[0]);
        expect(await testEnv.DB.prepare("SELECT completed_at FROM subscription_recovery_cursors WHERE environment='Production'").first()).toEqual({ completed_at: now + 120000 });
        await testEnv.DB.prepare("INSERT INTO subscription_recovery_lock(id,owner,lease_until) VALUES(1,'another-run',?1)").bind(Date.now() + day).run();
        fetcher.mockClear();
        expect(await recoverSubscriptions(enabled(), config, now + 180000, provider(fetcher))).toMatchObject({ busy: true });
        expect(fetcher).not.toHaveBeenCalled();
    });
    it("replays a successfully applied prefix after a later item fails without losing the page", async () => {
        const { tx, id } = await seed(`prefix-${randomHex(6)}`);
        const signed = await notice({ ...tx, revocationDate: now });
        let broken = true;
        const fetcher = vi.fn(async (input: RequestInfo | URL) => String(input).includes("sandbox") ? response({ hasMore: false, notificationHistory: [] }) : response({ hasMore: false, notificationHistory: [{ signedPayload: signed }, ...(broken ? [{ signedPayload: "bad" }] : [])] })) as typeof fetch;
        await recoverSubscriptions(enabled(), config, now, provider(fetcher));
        expect((await getEntitlement(testEnv.DB, id))?.status).toBe("revoked");
        expect(await testEnv.DB.prepare("SELECT completed_at FROM subscription_recovery_cursors WHERE environment='Production'").first()).toEqual({ completed_at: null });
        broken = false;
        await recoverSubscriptions(enabled(), config, now + 60000, provider(fetcher));
        expect(await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM notifications WHERE entitlement_id=?1").bind(id).first()).toEqual({ n: 1 });
        expect(await testEnv.DB.prepare("SELECT completed_at FROM subscription_recovery_cursors WHERE environment='Production'").first()).toEqual({ completed_at: now + 60000 });
    });
    it("validates nested history renewal identity before applying grace", async () => {
        const { tx, id } = await seed(`nested-${randomHex(6)}`, { expiresDate: now - 1000 });
        const signed = await signCompactJws({ notificationType: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD", notificationUUID: crypto.randomUUID(), signedDate: now, data: { bundleId: config.bundleId, appAppleId: config.appAppleId, environment: "Production", signedTransactionInfo: await signCompactJws(tx, chain), signedRenewalInfo: await signCompactJws({ originalTransactionId: "another", productId: tx.productId, environment: "Production", signedDate: now, gracePeriodExpiresDate: now + day }, chain) } }, chain);
        const fetcher = vi.fn(async () => response({ hasMore: false, notificationHistory: [{ signedPayload: signed }] })) as typeof fetch;
        await recoverSubscriptions(enabled(), config, now, provider(fetcher));
        expect((await getEntitlement(testEnv.DB, id))?.grace_until).toBeNull();
    });
    it("accepts a bounded history body larger than a bare transaction and rejects oversized streams", async () => {
        const fetcher = vi.fn(async () => response({ hasMore: false, notificationHistory: [], padding: "x".repeat(100000) })) as typeof fetch;
        expect((await getNotificationHistory({ ...api, fetch: fetcher }, { startDate: now - day, endDate: now }, now)).body).toMatchObject({ hasMore: false });
        await expect(getNotificationHistory({ ...api, fetch: async () => response({ padding: "x".repeat(2 * 1024 * 1024) }) }, { startDate: now - day, endDate: now }, now)).rejects.toThrow("exceeds limit");
    });
    it("encodes cursor and sends exact history body", async () => { const fetcher = vi.fn(async () => response({ hasMore: false, notificationHistory: [] })) as typeof fetch & ReturnType<typeof vi.fn>; await getNotificationHistory({ ...api, fetch: fetcher }, { startDate: now - day, endDate: now, paginationToken: "a/b?c" }, now); const [url, init] = fetcher.mock.calls[0]!; expect(String(url)).toContain("paginationToken=a%2Fb%3Fc"); expect(JSON.parse(String(init?.body))).toEqual({ startDate: now - day, endDate: now }); await getAllSubscriptionStatuses({ ...api, fetch: fetcher }, "123456", now); expect(String(fetcher.mock.calls[1]![0])).toContain("/inApps/v1/subscriptions/123456"); });
    it("actual notification switch restores legacy ordering while recovery guards older events", async () => {
        for (const flag of ["0", "1"]) {
            const { tx, id } = await seed(`switch-${flag}-${randomHex(6)}`);
            const env = { ...testEnv, SUBSCRIPTION_RECOVERY_ENABLED: flag };
            const decoded = async (expiresDate: number, signedDate: number) => ({ notificationType: "DID_RENEW", notificationUUID: crypto.randomUUID(), signedDate,
                data: { bundleId: config.bundleId, appAppleId: config.appAppleId, environment: "Production", signedTransactionInfo: await signCompactJws({ ...tx, expiresDate }, chain) } });
            await applyNotification(env, config, await decoded(now + 30 * day, now), now);
            await applyNotification(env, config, await decoded(now + 60 * day, now - 1000), now);
            expect((await getEntitlement(testEnv.DB, id))?.expires_at).toBe(now + (flag === "0" ? 60 : 30) * day);
        }
    });
    it("does not let a signed Apple refresh change the verified app transaction identity", async () => {
        const tx = transactionPayload({ originalTransactionId: `consent-${randomHex(6)}` }, now);
        const mismatched = { ...tx, appTransactionId: "another-app-transaction" };
        await expect(refreshSubscriptionFromApple(enabled(), config, tx as never, now, { ...api, fetch: async () => response({ signedTransactionInfo: await signCompactJws(mismatched, chain) }) })).rejects.toThrow("app transaction mismatch");
    });
    it("times out a stuck revocation RPC without consuming its retry record", async () => {
        const { tx, id } = await seed(`rpc-timeout-${randomHex(6)}`);
        await upsertEntitlement(testEnv.DB, { id, productId: String(tx.productId), environment: "Production", status: "revoked", expiresAt: now + day, purchaseAt: Number(tx.purchaseDate), revokedAt: now, notificationSignedAt: now, source: "notification" }, now);
        const device = randomHex();
        await testEnv.DB.prepare("INSERT INTO entitlement_devices (entitlement_id,device_id,first_seen,last_seen,last_room) VALUES (?1,?2,?3,?3,?4)").bind(id, device, now, randomHex()).run();
        const env = { ...enabled(), ROOM: { idFromName: (x: string) => x, get: () => ({ revokeEntitlement: () => new Promise(() => { }) }) } } as unknown as Env;
        const fetcher = vi.fn(async () => response({ hasMore: false, notificationHistory: [] })) as typeof fetch;
        await recoverSubscriptions(env, config, now, provider(fetcher));
        expect(await testEnv.DB.prepare("SELECT * FROM subscription_recovery_revocations WHERE entitlement_id=?1").bind(id).first()).not.toBeNull();
        expect(await testEnv.DB.prepare("SELECT * FROM subscription_recovery_lock").first()).toBeNull();
    });
    it("selects the requested signed lineage despite unrelated unconfigured customer subscriptions", async () => {
      const { tx, id } = await seed(`other-lineage-${randomHex(6)}`, { expiresDate: now - 1000 });
      const body = await statuses(tx, { gracePeriodExpiresDate: now + day });
      body.data[0]!.lastTransactions.unshift({ status: 1, originalTransactionId: "irrelevant", signedTransactionInfo: await signCompactJws({ ...tx, originalTransactionId: "other", productId: "unconfigured-old-product" }, chain), signedRenewalInfo: "not-used" });
      const fetcher = vi.fn(async (input: RequestInfo | URL) => String(input).includes("/history") ? response({ hasMore: false, notificationHistory: [] }) : response(body)) as typeof fetch;
      await recoverSubscriptions(enabled(), config, now, provider(fetcher));
      expect(await getEntitlement(testEnv.DB, id)).toMatchObject({ status: "grace", grace_until: now + day });
    });

});
