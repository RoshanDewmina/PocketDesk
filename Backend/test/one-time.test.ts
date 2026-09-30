import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { loadConfig } from "../src/config";
import * as appleApi from "../src/apple/server-api";
import { oneTimeCatalog, ONE_TIME_VERIFICATION_MS } from "../src/entitlement/one-time-policy";
import { checkTransactionPolicy, handleVerify, parseTransactionPayload } from "../src/entitlement/verify";
import { accessEndMs, entitlementIdFor, getEntitlement, hasAccess, linkDevice, purgeRetention, upsertEntitlement } from "../src/entitlement/store";
import { mintEntitlementToken } from "../src/entitlement/token";
import { applyNotification } from "../src/entitlement/notifications";
import { parseChain, signCompactJws, transactionPayload, type TestChain } from "./helpers/apple-chain";
import { connectHost, connectClient, pairing, testEnv } from "./helpers/client";
import { randomHex } from "../src/util";

const lifetime = "test.farside.one-time.lifetime", founder = "test.farside.one-time.founder";
let chain: TestChain;
beforeAll(() => { chain = parseChain(testEnv.TEST_APPLE_CHAIN); });
const config = () => ({ ...loadConfig(testEnv), oneTimeProducts: oneTimeCatalog({ lifetime, founder }, loadConfig(testEnv).allowedProductIds) });
const payload = (extra: Record<string, unknown> = {}) => transactionPayload({ type: "Non-Consumable", productId: lifetime, expiresDate: undefined,
  originalTransactionId: `one-${randomHex(6)}`, ...extra });

async function verify(signed: string, overrides: Partial<Env> = {}) {
  const ctx = createExecutionContext();
  const result = await handleVerify(new Request("https://farside.test/v1/entitlements/verify", {
    method: "POST", headers: { "content-type": "application/json", "cf-connecting-ip": `198.51.100.${Math.floor(Math.random()*250)}` },
    body: JSON.stringify({ signedTransaction: signed, deviceId: randomHex() }),
  }), { ...testEnv, ...overrides }, ctx, config());
  await waitOnExecutionContext(ctx);
  return { status: result.status, body: await result.json() as Record<string, unknown> };
}

describe("disabled one-time catalog and typed rights", () => {
  it("defaults absent; unknown, duplicate, subscription collision and wrong signed type rejected", () => {
    expect(loadConfig(testEnv).oneTimeProducts?.size).toBe(0);
    expect(oneTimeCatalog({}, new Set()).size).toBe(0);
    expect(() => oneTimeCatalog({ lifetime, founder: lifetime }, new Set())).toThrow();
    expect(() => oneTimeCatalog({ lifetime }, new Set([lifetime]))).toThrow();
    const tx = parseTransactionPayload(payload())!;
    expect(checkTransactionPolicy(tx, loadConfig(testEnv))).toBe("wrong_product");
    expect(checkTransactionPolicy(tx, config())).toBeUndefined();
    expect(checkTransactionPolicy({ ...tx, type: "Consumable" }, config())).toBe("not_subscription");
    expect(checkTransactionPolicy({ ...tx, expiresDate: Date.now()+1000 }, config())).toBe("not_subscription");
    expect(checkTransactionPolicy({ ...tx, inAppOwnershipType: "FAMILY_SHARED" }, config())).toBe("not_purchased");
  });
  it("migrates old rows to subscription; both benefits expire authorization from actual verification, not entitlement age", async () => {
    const now = Date.now(), sub = randomHex(), life = randomHex(), founding = randomHex();
    await upsertEntitlement(testEnv.DB, { id: sub, productId: "com.roshan.PocketDesk.remote.monthly", environment: "Production", status: "active", expiresAt: now+1000, source: "verify" }, now);
    expect((await getEntitlement(testEnv.DB, sub))?.kind).toBe("subscription");
    for (const [id, kind, productId] of [[life,"lifetime",lifetime],[founding,"founder",founder]] as const) {
      await upsertEntitlement(testEnv.DB, { id, kind, productId, environment: "Production", status: "active", expiresAt: 0, purchaseAt: now-10000, source: "verify" }, now);
      const row = (await getEntitlement(testEnv.DB,id))!;
      expect(row.expires_at).toBe(0); expect(hasAccess(row, now, config().oneTimeProducts)).toBe(true);
      expect(accessEndMs(row)).toBe(now+ONE_TIME_VERIFICATION_MS);
      expect(hasAccess(row, now)).toBe(false);
      expect(hasAccess(row, now, new Map([[productId, kind === "lifetime" ? "founder" : "lifetime"]]))).toBe(false);
      expect(hasAccess(row, now+ONE_TIME_VERIFICATION_MS, config().oneTimeProducts)).toBe(false);
      expect(hasAccess({ ...row, last_verified_at: null }, now, config().oneTimeProducts)).toBe(false);
      expect(hasAccess({ ...row, last_verified_at: now+1 }, now, config().oneTimeProducts)).toBe(false);
    }
  });
  it("refund tombstone survives retention and stale restore, while unrelated subscription stays active", async () => {
    const now=Date.now(), id=randomHex(), sub=randomHex();
    const base={id,kind:"lifetime" as const,productId:lifetime,environment:"Production",expiresAt:0,purchaseAt:now-10000,source:"verify" as const};
    await upsertEntitlement(testEnv.DB,{...base,status:"active"},now);
    await upsertEntitlement(testEnv.DB,{...base,status:"revoked",revokedAt:now-1000,source:"notification"},now);
    await upsertEntitlement(testEnv.DB,{...base,status:"active",revokedAt:null},now);
    expect((await getEntitlement(testEnv.DB,id))?.status).toBe("revoked");
    await upsertEntitlement(testEnv.DB,{id:sub,productId:"com.roshan.PocketDesk.remote.monthly",environment:"Production",expiresAt:now+100000,status:"active",source:"verify"},now);
    expect(hasAccess((await getEntitlement(testEnv.DB,sub))!,now)).toBe(true);
    await purgeRetention(testEnv.DB,now+400*86400000);
    expect((await getEntitlement(testEnv.DB,id))?.status).toBe("revoked");
    // Only Apple's signed refund reversal (handler passes this flag) restores that same purchase.
    await upsertEntitlement(testEnv.DB,{...base,status:"active",revokedAt:null,refundReversed:true,source:"notification"},now);
    expect((await getEntitlement(testEnv.DB,id))?.status).toBe("active");
  });
  it("a saved valid token cannot obtain relay after the catalog is absent on the actual Room", async () => {
    const now=Date.now(),id=randomHex(),device=randomHex(),p=await pairing();
    await upsertEntitlement(testEnv.DB,{id,kind:"lifetime",productId:lifetime,environment:"Production",status:"active",expiresAt:0,source:"verify"},now);
    await linkDevice(testEnv.DB,id,device,now,3);
    const token=await mintEntitlementToken(testEnv.ENTITLEMENT_TOKEN_KEY,{v:1,d:device,s:id,x:Math.floor((now+ONE_TIME_VERIFICATION_MS)/1000),n:"P",e:"test"});
    const host=await connectHost(p,{features:["remote.1","route.1"]});
    let phone: Awaited<ReturnType<typeof connectClient>> | undefined;
    try {
      phone=await connectClient(p,{features:["remote.1","route.1"],entitlementToken:token});
      expect(phone.pre).toContainEqual(expect.objectContaining({type:"error",code:"entitlement_required"}));
      expect(phone.ice).toMatchObject({type:"ice",servers:[]});
      const route=await phone.next();expect(route).toMatchObject({type:"route",access:"local"});
    } finally {phone?.close();host.close();}
  });
  it("real one-time verification fails closed without Apple current-transaction configuration", async () => {
    const result=await verify(await signCompactJws(payload(),chain),{APPLE_IAP_ISSUER_ID:"",APPLE_IAP_KEY_ID:"",APPLE_IAP_PRIVATE_KEY:""});
    expect(result.status).toBe(503); expect(result.body).not.toHaveProperty("entitlementToken");
  });
  it("current verified Apple transaction issues bounded token with no invented economic expiry; mismatched and refunded replies denied", async () => {
    const tx=payload(), signed=await signCompactJws(tx,chain);
    const mock=vi.spyOn(appleApi,"getTransactionInfo");
    const keys={APPLE_IAP_ISSUER_ID:"TEST ONLY",APPLE_IAP_KEY_ID:"TEST ONLY",APPLE_IAP_PRIVATE_KEY:"TEST ONLY"};
    try {
      mock.mockResolvedValue({status:200,body:{signedTransactionInfo:signed}});
      const before=Date.now(),ok=await verify(signed,keys);
      expect(ok.body.entitled).toBe(true); expect(ok.body.entitlementKind).toBe("lifetime");
      expect(ok.body).not.toHaveProperty("expiresAt");
      expect(Date.parse(String(ok.body.tokenExpiresAt))).toBeLessThanOrEqual(Date.now()+ONE_TIME_VERIFICATION_MS);
      expect(Date.parse(String(ok.body.tokenExpiresAt))).toBeGreaterThan(before);
      mock.mockResolvedValue({status:200,body:{signedTransactionInfo:await signCompactJws({...tx,productId:founder},chain)}});
      expect((await verify(signed,keys)).status).toBe(401);
      mock.mockResolvedValue({status:200,body:{signedTransactionInfo:await signCompactJws({...tx,revocationDate:Date.now()},chain)}});
      expect((await verify(signed,keys)).body).toMatchObject({entitled:false,reason:"revoked"});
    } finally {mock.mockRestore();}
  });
  it("nonconsumable renewal expiry cannot remove rights; refund/reversal applies without forging verification freshness", async () => {
    const now=Date.now(),tx=payload(),id=await entitlementIdFor(testEnv.ENTITLEMENT_HASH_KEY,String(tx.originalTransactionId));
    await upsertEntitlement(testEnv.DB,{id,kind:"lifetime",productId:lifetime,environment:"Production",expiresAt:0,status:"active",purchaseAt:Number(tx.purchaseDate),source:"verify"},now);
    async function notify(type:string, extra:Record<string,unknown>={}) {
      return applyNotification(testEnv,config(),{notificationType:type,notificationUUID:randomHex(16),data:{bundleId:config().bundleId,environment:"Production",appAppleId:config().appAppleId,
        signedTransactionInfo:await signCompactJws({...tx,...extra},chain)}},now+1000);
    }
    expect(await notify("EXPIRED")).toBe("recorded"); expect((await getEntitlement(testEnv.DB,id))?.status).toBe("active");
    expect(await notify("REFUND",{revocationDate:now+1})).toBe("applied"); expect((await getEntitlement(testEnv.DB,id))?.status).toBe("revoked");
    expect(await notify("REFUND_REVERSED")).toBe("applied");
    const restored=(await getEntitlement(testEnv.DB,id))!;expect(restored.status).toBe("active");expect(restored.last_verified_at).toBe(now);
  });
});
