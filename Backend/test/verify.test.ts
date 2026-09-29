import { SELF } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { mintEntitlementToken } from "../src/entitlement/token";
import { entitlementIdFor } from "../src/entitlement/store";
import { randomHex } from "../src/util";
import { parseChain, signCompactJws, transactionPayload, type TestChain } from "./helpers/apple-chain";
import { postJson, testEnv } from "./helpers/client";

let chain: TestChain;
const now = Date.now();
let ipCounter = 10;
const freshIp = () => ({ "cf-connecting-ip": `198.51.100.${ipCounter++ % 250}` });

async function verify(overrides: Record<string, unknown> = {}, deviceId = randomHex(), headers: Record<string, string> = freshIp()) {
  const signedTransaction = await signCompactJws(transactionPayload(overrides, now), chain);
  const response = await postJson("/v1/entitlements/verify", { signedTransaction, deviceId }, headers);
  return { status: response.status, body: await response.json() as Record<string, unknown>, headers: response.headers };
}

beforeAll(() => { chain = parseChain(testEnv.TEST_APPLE_CHAIN); });

describe("POST /v1/entitlements/verify", () => {
  it("entitles a valid production subscription and stores only a hashed identifier", async () => {
    const otid = `otid-${randomHex(8)}`;
    const deviceId = randomHex();
    const { status, body, headers } = await verify({ originalTransactionId: otid, transactionId: otid }, deviceId);
    expect(status).toBe(200);
    expect(body.entitled).toBe(true);
    expect(body.environment).toBe("Production");
    expect(body.productId).toBe("com.roshan.PocketDesk.remote.monthly");
    expect(body.inGracePeriod).toBe(false);
    expect(String(body.entitlementToken).startsWith("fe1.")).toBe(true);
    expect(Date.parse(String(body.tokenExpiresAt)) - now).toBeLessThanOrEqual(24 * 60 * 60 * 1000 + 5000);
    expect(headers.get("x-content-type-options")).toBe("nosniff");
    expect(headers.get("cache-control")).toBe("no-store");

    const id = await entitlementIdFor(testEnv.ENTITLEMENT_HASH_KEY, otid);
    const rows = (await testEnv.DB.prepare("SELECT id, status, environment FROM entitlements WHERE id = ?1").bind(id).all<{ id: string; status: string; environment: string }>()).results;
    expect(rows).toHaveLength(1);
    expect(rows[0]!.id).toMatch(/^[a-f0-9]{64}$/);
    expect(rows[0]!.id).not.toContain(otid);
    expect(rows[0]!.status).toBe("active");
    expect((await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM entitlements WHERE id LIKE ?1").bind(`%${otid}%`).first<{ n: number }>())?.n).toBe(0);
    const devices = (await testEnv.DB.prepare("SELECT device_id FROM entitlement_devices WHERE entitlement_id = ?1").bind(id).all<{ device_id: string }>()).results;
    expect(devices.map(row => row.device_id)).toEqual([deviceId]);
    expect(JSON.stringify(body)).not.toContain(otid);
  });

  it("accepts sandbox transactions and flags them", async () => {
    const otid = `sb-${randomHex(6)}`;
    const { status, body } = await verify({ environment: "Sandbox", originalTransactionId: otid });
    expect(status).toBe(200);
    expect(body.entitled).toBe(true);
    expect(body.environment).toBe("Sandbox");
    const row = await testEnv.DB.prepare("SELECT environment FROM entitlements WHERE id = ?1").bind(await entitlementIdFor(testEnv.ENTITLEMENT_HASH_KEY, otid)).first<{ environment: string }>();
    expect(row?.environment).toBe("Sandbox");
  });

  it("returns entitled:false for expired and revoked subscriptions without a token", async () => {
    const expired = await verify({ expiresDate: now - 1000, originalTransactionId: `ex-${randomHex(6)}` });
    expect(expired.status).toBe(200);
    expect(expired.body).toMatchObject({ entitled: false, reason: "expired" });
    expect(expired.body.entitlementToken).toBeUndefined();
    const revoked = await verify({ revocationDate: now - 500, revocationReason: 0, originalTransactionId: `rv-${randomHex(6)}` });
    expect(revoked.body).toMatchObject({ entitled: false, reason: "revoked" });
  });

  it("rejects transactions for another app, product, type or environment", async () => {
    expect((await verify({ bundleId: "com.example.other" })).body).toEqual({ error: "invalid_transaction", reason: "wrong_app" });
    expect((await verify({ productId: "com.roshan.PocketDesk.remote.lifetime" })).body).toEqual({ error: "invalid_transaction", reason: "wrong_product" });
    expect((await verify({ type: "Consumable" })).body).toEqual({ error: "invalid_transaction", reason: "not_subscription" });
    const xcode = await verify({ environment: "Xcode" });
    expect(xcode.status).toBe(401);
    expect(xcode.body).toEqual({ error: "invalid_transaction", reason: "environment_not_accepted" });
  });

  it("rejects a tampered or foreign JWS with 401 signature", async () => {
    const tampered = await signCompactJws(transactionPayload({}, now), chain, { tamperPayload: true });
    const response = await postJson("/v1/entitlements/verify", { signedTransaction: tampered, deviceId: randomHex() }, freshIp());
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "invalid_transaction", reason: "signature" });
  });

  it("rejects malformed requests before touching Apple data", async () => {
    const badDevice = await postJson("/v1/entitlements/verify", { signedTransaction: "a.b.c", deviceId: "not-hex" }, freshIp());
    expect(badDevice.status).toBe(400);
    const notJson = await postJson("/v1/entitlements/verify", "{", freshIp());
    expect(notJson.status).toBe(400);
    const huge = await postJson("/v1/entitlements/verify", { signedTransaction: "x".repeat(40 * 1024), deviceId: randomHex() }, freshIp());
    expect(huge.status).toBe(400);
    expect((await SELF.fetch("https://farside.test/v1/entitlements/verify")).status).toBe(404);
  });

  it("caps devices per subscription at three and frees a slot on forget", async () => {
    const otid = `cap-${randomHex(6)}`;
    const devices = [randomHex(), randomHex(), randomHex(), randomHex()];
    const results = [];
    for (const device of devices) results.push(await verify({ originalTransactionId: otid }, device));
    expect(results.slice(0, 3).every(result => result.body.entitled === true)).toBe(true);
    expect(results[3]!.body).toMatchObject({ entitled: false, reason: "device_limit" });

    const again = await verify({ originalTransactionId: otid }, devices[0]!);
    expect(again.body.entitled).toBe(true);

    const forget = await postJson("/v1/entitlements/forget", { deviceId: devices[0], entitlementToken: results[0]!.body.entitlementToken }, freshIp());
    expect(forget.status).toBe(204);
    const fourth = await verify({ originalTransactionId: otid }, devices[3]!);
    expect(fourth.body.entitled).toBe(true);
  });

  it("holds the device cap under parallel verification and allows one device per sandbox purchase", async () => {
    const otid = `par-${randomHex(6)}`;
    const results = await Promise.all(Array.from({ length: 6 }, () => verify({ originalTransactionId: otid })));
    expect(results.filter(result => result.body.entitled === true)).toHaveLength(3);
    expect(results.filter(result => result.body.reason === "device_limit")).toHaveLength(3);

    const sandbox = `sbx-${randomHex(6)}`;
    expect((await verify({ originalTransactionId: sandbox, environment: "Sandbox" })).body.entitled).toBe(true);
    expect((await verify({ originalTransactionId: sandbox, environment: "Sandbox" })).body).toMatchObject({ entitled: false, reason: "device_limit" });
  });

  it("refuses forget with a token for another device or a forged token", async () => {
    const first = await verify({ originalTransactionId: `fg-${randomHex(6)}` });
    const otherDevice = await postJson("/v1/entitlements/forget", { deviceId: randomHex(), entitlementToken: first.body.entitlementToken }, freshIp());
    expect(otherDevice.status).toBe(401);
    const forged = await mintEntitlementToken("wrong-key-0123456789abcdef0123456789abcdef", { v: 1, d: "a".repeat(64), s: "b".repeat(64), x: Math.floor(now / 1000) + 60, n: "P", e: "test" });
    const forgedResponse = await postJson("/v1/entitlements/forget", { deviceId: "a".repeat(64), entitlementToken: forged }, freshIp());
    expect(forgedResponse.status).toBe(401);
  });

  it("rate-limits repeated verification from one device", async () => {
    const deviceId = randomHex();
    const statuses: number[] = [];
    for (let i = 0; i < 8; i++) statuses.push((await verify({ originalTransactionId: `rl-${randomHex(6)}` }, deviceId)).status);
    expect(statuses.slice(0, 6)).toEqual([200, 200, 200, 200, 200, 200]);
    expect(statuses.slice(6)).toEqual([429, 429]);
  });
});
