import { beforeAll, describe, expect, it } from "vitest";
import { entitlementIdFor } from "../src/entitlement/store";
import { randomHex } from "../src/util";
import { generateTestChain, parseChain, signCompactJws, transactionPayload, type TestChain } from "./helpers/apple-chain";
import { connectClient, connectHost, pairing, postJson, sleep, testEnv } from "./helpers/client";
import { installTurnMock, type TurnMock } from "./helpers/turn-mock";

let chain: TestChain;
let turn: TurnMock;
const now = Date.now();
const day = 24 * 60 * 60 * 1000;
let ipCounter = 30;
const freshIp = () => ({ "cf-connecting-ip": `198.51.100.${ipCounter++ % 250}` });

async function notification(type: string, options: { subtype?: string; tx?: Record<string, unknown>; renewal?: Record<string, unknown>; data?: Record<string, unknown>; uuid?: string; signer?: TestChain } = {}) {
  const signer = options.signer ?? chain;
  const tx = transactionPayload(options.tx ?? {}, now);
  const renewal = { originalTransactionId: tx.originalTransactionId, productId: tx.productId, autoRenewStatus: 1, environment: "Production", signedDate: now, ...options.renewal };
  const decoded = {
    notificationType: type,
    ...(options.subtype ? { subtype: options.subtype } : {}),
    notificationUUID: options.uuid ?? crypto.randomUUID(),
    version: "2.0",
    signedDate: now,
    data: {
      appAppleId: 1234567890,
      bundleId: "com.roshan.PocketDesk.Remote",
      bundleVersion: "1",
      environment: "Production",
      signedTransactionInfo: await signCompactJws(tx, signer),
      signedRenewalInfo: await signCompactJws(renewal, signer),
      ...options.data,
    },
  };
  const signedPayload = await signCompactJws(decoded, signer);
  const response = await postJson("/v1/appstore/notifications", { signedPayload }, freshIp());
  return { status: response.status, body: await response.json() as Record<string, unknown>, tx };
}

async function verify(tx: Record<string, unknown>, deviceId = randomHex()) {
  const signedTransaction = await signCompactJws(transactionPayload(tx, now), chain);
  const response = await postJson("/v1/entitlements/verify", { signedTransaction, deviceId }, freshIp());
  return (await response.json()) as Record<string, unknown>;
}

// Storage is isolated per test file, not per test, so every lookup is by the subscription under test.
const row = async (otid: string) => testEnv.DB.prepare("SELECT status, expires_at, grace_until, revoked_at FROM entitlements WHERE id = ?1")
  .bind(await entitlementIdFor(testEnv.ENTITLEMENT_HASH_KEY, otid))
  .first<{ status: string; expires_at: number; grace_until: number | null; revoked_at: number | null }>();

beforeAll(() => {
  chain = parseChain(testEnv.TEST_APPLE_CHAIN);
  turn = installTurnMock();
});

describe("POST /v1/appstore/notifications", () => {
  it("records a renewal for a subscription it has not seen and extends a known one", async () => {
    const otid = `n-${randomHex(6)}`;
    const first = await notification("DID_RENEW", { tx: { originalTransactionId: otid, expiresDate: now + 30 * day } });
    expect(first.status).toBe(200);
    expect(first.body.outcome).toBe("applied");
    expect((await row(otid))?.status).toBe("active");
    const later = await notification("DID_RENEW", { tx: { originalTransactionId: otid, expiresDate: now + 60 * day } });
    expect(later.body.outcome).toBe("applied");
    expect((await row(otid))?.expires_at).toBe(now + 60 * day);
    const id = await entitlementIdFor(testEnv.ENTITLEMENT_HASH_KEY, otid);
    expect((await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM notifications WHERE entitlement_id = ?1").bind(id).first<{ n: number }>())?.n).toBe(2);
  });

  it("keeps access through a billing grace period and ends it when Apple says so", async () => {
    const otid = `g-${randomHex(6)}`;
    const deviceId = randomHex();
    // The paid period has ended (as it has when Apple sends DID_FAIL_TO_RENEW); on its own that means no access.
    expect((await verify({ originalTransactionId: otid, expiresDate: now - 1000 }, deviceId))).toMatchObject({ entitled: false, reason: "expired" });
    const grace = await notification("DID_FAIL_TO_RENEW", {
      subtype: "GRACE_PERIOD",
      tx: { originalTransactionId: otid, expiresDate: now - 1000 },
      renewal: { gracePeriodExpiresDate: now + 16 * day, isInBillingRetryPeriod: true },
    });
    expect(grace.body.outcome).toBe("applied");
    expect(await row(otid)).toMatchObject({ status: "grace", grace_until: now + 16 * day });
    const stillEntitled = await verify({ originalTransactionId: otid, expiresDate: now - 1000 }, deviceId);
    expect(stillEntitled.entitled).toBe(true);
    expect(stillEntitled.inGracePeriod).toBe(true);
    expect(Date.parse(String(stillEntitled.tokenExpiresAt))).toBeLessThanOrEqual(now + day + 5000);

    await notification("GRACE_PERIOD_EXPIRED", { tx: { originalTransactionId: otid, expiresDate: now - 1000 } });
    expect((await row(otid))?.status).toBe("expired");
    expect((await verify({ originalTransactionId: otid, expiresDate: now - 1000 }, deviceId))).toMatchObject({ entitled: false, reason: "expired" });
  });

  it("marks EXPIRED subscriptions expired", async () => {
    const otid = `e-${randomHex(6)}`;
    await verify({ originalTransactionId: otid, expiresDate: now + day });
    const expired = await notification("EXPIRED", { subtype: "VOLUNTARY", tx: { originalTransactionId: otid, expiresDate: now - 60_000 } });
    expect(expired.body.outcome).toBe("applied");
    expect((await row(otid))?.status).toBe("expired");
  });

  it("revokes on REFUND, ends a live entitled room at once and revokes its relay credentials", async () => {
    turn.reset();
    const otid = `r-${randomHex(6)}`;
    const deviceId = randomHex();
    const verified = await verify({ originalTransactionId: otid }, deviceId);
    expect(verified.entitled).toBe(true);

    const p = await pairing();
    const host = await connectHost(p, { features: ["remote.1"] });
    const client = await connectClient(p, { features: ["remote.1"], entitlement: verified.entitlementToken });
    expect(client.registered.access).toBe("remote");
    expect((await host.next()).type).toBe("ice");
    expect((await host.next()).online).toBe(true);
    expect((await client.next()).online).toBe(true);
    expect(turn.issued).toHaveLength(2);

    const refund = await notification("REFUND", { tx: { originalTransactionId: otid, revocationDate: now, revocationReason: 0 } });
    expect(refund.body.outcome).toBe("applied");
    const [hostClose, clientClose] = await Promise.all([host.closed, client.closed]);
    expect(hostClose.reason).toBe("entitlement_revoked");
    expect(clientClose.reason).toBe("entitlement_revoked");
    expect(await row(otid)).toMatchObject({ status: "revoked" });
    await sleep(50);
    expect([...turn.revoked].sort()).toEqual([...turn.issued].sort());
    expect(await verify({ originalTransactionId: otid }, deviceId)).toMatchObject({ entitled: false, reason: "revoked" });

    const reversed = await notification("REFUND_REVERSED", { tx: { originalTransactionId: otid } });
    expect(reversed.body.outcome).toBe("applied");
    expect((await row(otid))?.status).toBe("active");
  });

  it("a renewal-preference change during grace keeps the grace period; a new purchase after a refund is valid", async () => {
    const otid = `p-${randomHex(6)}`;
    await notification("DID_FAIL_TO_RENEW", { subtype: "GRACE_PERIOD", tx: { originalTransactionId: otid, expiresDate: now - 1000 }, renewal: { gracePeriodExpiresDate: now + 10 * day } });
    await notification("DID_CHANGE_RENEWAL_PREF", { subtype: "DOWNGRADE", tx: { originalTransactionId: otid, expiresDate: now - 1000 } });
    expect(await row(otid)).toMatchObject({ status: "grace", grace_until: now + 10 * day });

    const refunded = `q-${randomHex(6)}`;
    const deviceId = randomHex();
    await verify({ originalTransactionId: refunded }, deviceId);
    await notification("REFUND", { tx: { originalTransactionId: refunded, revocationDate: now - 60_000, revocationReason: 1 } });
    expect((await verify({ originalTransactionId: refunded }, deviceId))).toMatchObject({ entitled: false, reason: "revoked" });
    const repurchased = await verify({ originalTransactionId: refunded, transactionId: "2000000999999999", purchaseDate: now - 1000, expiresDate: now + 30 * day }, deviceId);
    expect(repurchased.entitled).toBe(true);
  });

  it("accepts a notification the size of a real one and refuses embedded tokens beyond their own limit", async () => {
    const otid = `big-${randomHex(6)}`;
    const big = await notification("DID_RENEW", { tx: { originalTransactionId: otid }, data: { bundleVersion: "1".repeat(20 * 1024) } });
    expect(big.status).toBe(200);
    expect(big.body.outcome).toBe("applied");
    const tooBig = await notification("DID_RENEW", { tx: { originalTransactionId: otid }, data: { bundleVersion: "1".repeat(50 * 1024) } });
    expect(tooBig.status).toBe(401);
    const oversizedEmbedded = await notification("DID_RENEW", { tx: { originalTransactionId: otid, storefront: "x".repeat(17 * 1024) } });
    expect(oversizedEmbedded.status).toBe(200);
    expect(oversizedEmbedded.body.outcome).toBe("recorded");
  });

  it("a delayed retry of an older renewal cannot undo a refund, and a refund of an earlier period keeps the current one", async () => {
    const otid = `late-${randomHex(6)}`;
    const deviceId = randomHex();
    await verify({ originalTransactionId: otid, purchaseDate: now - 40 * day, expiresDate: now + 20 * day }, deviceId);
    await notification("REFUND", { tx: { originalTransactionId: otid, purchaseDate: now - 40 * day, expiresDate: now + 20 * day, revocationDate: now - 60_000, revocationReason: 0 } });
    expect((await row(otid))?.status).toBe("revoked");
    const late = await notification("DID_RENEW", { tx: { originalTransactionId: otid, purchaseDate: now - 40 * day, expiresDate: now + 20 * day } });
    expect(late.body.outcome).toBe("applied");
    expect((await row(otid))?.status).toBe("revoked");
    expect((await verify({ originalTransactionId: otid, purchaseDate: now - 40 * day, expiresDate: now + 20 * day }, deviceId))).toMatchObject({ entitled: false, reason: "revoked" });

    const yearly = `year-${randomHex(6)}`;
    const device2 = randomHex();
    const newerPurchase = await verify({ originalTransactionId: yearly, transactionId: "2000000000000002", purchaseDate: now - day, expiresDate: now + 29 * day }, device2);
    expect(newerPurchase.entitled).toBe(true);
    const p = await pairing();
    const host = await connectHost(p);
    const client = await connectClient(p, { features: ["remote.1"], entitlement: newerPurchase.entitlementToken });
    expect(client.registered.access).toBe("remote");
    await host.next(); await host.next(); await client.next();
    const earlierPeriod = await notification("REFUND", { tx: { originalTransactionId: yearly, transactionId: "2000000000000001", purchaseDate: now - 31 * day, expiresDate: now - day, revocationDate: now - 1000, revocationReason: 0 } });
    expect(earlierPeriod.body.outcome).toBe("recorded");
    expect((await verify({ originalTransactionId: yearly, transactionId: "2000000000000002", purchaseDate: now - day, expiresDate: now + 29 * day }, device2)).entitled).toBe(true);
    expect(host.ws.readyState).toBe(WebSocket.OPEN);
    expect(client.ws.readyState).toBe(WebSocket.OPEN);
    client.close(); host.close();
  });

  it("deduplicates by notificationUUID and records unknown types", async () => {
    const uuid = crypto.randomUUID();
    const first = await notification("TEST", { uuid, data: { signedTransactionInfo: undefined, signedRenewalInfo: undefined } });
    expect(first.status).toBe(200);
    expect(first.body.outcome).toBe("recorded");
    const again = await notification("TEST", { uuid, data: { signedTransactionInfo: undefined, signedRenewalInfo: undefined } });
    expect(again.body.outcome).toBe("duplicate");
    const other = await notification("CONSUMPTION_REQUEST", { tx: { originalTransactionId: `c-${randomHex(6)}` } });
    expect(other.body.outcome).toBe("recorded");
  });

  it("ignores another app's notifications and rejects unsigned or foreign payloads", async () => {
    const otherApp = await notification("DID_RENEW", { data: { bundleId: "com.example.other" } });
    expect(otherApp.status).toBe(200);
    expect(otherApp.body.outcome).toBe("ignored_other_app");
    const foreign = await notification("DID_RENEW", { signer: await generateTestChain({ now }) });
    expect(foreign.status).toBe(401);
    expect(foreign.body).toEqual({ error: "invalid_signature" });
    const missing = await postJson("/v1/appstore/notifications", { nope: true }, freshIp());
    expect(missing.status).toBe(400);
  });
});
