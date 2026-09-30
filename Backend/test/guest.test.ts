import { SELF, evictDurableObject } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { guestCanonical, grantFields, type GuestGrant } from "../src/guest";
import { base64Encode, randomHex, sha256Hex } from "../src/util";
import { parseChain, signCompactJws, transactionPayload, type TestChain } from "./helpers/apple-chain";
import { connectClient, connectHost, open, pairing, payload64, postJson, sleep, testEnv } from "./helpers/client";
import { installTurnMock, type TurnMock } from "./helpers/turn-mock";
import type { RoomDO } from "../src/room";
let chain: TestChain, turn: TurnMock;
beforeAll(() => { chain = parseChain(testEnv.TEST_APPLE_CHAIN); turn = installTurnMock(); });
async function paidToken() {
 const now = Date.now(), signedTransaction = await signCompactJws(transactionPayload({originalTransactionId:`guest-${randomHex(6)}`,expiresDate:now+86400000},now),chain);
 const response = await postJson("/v1/entitlements/verify",{signedTransaction,deviceId:randomHex()},{"cf-connecting-ip":`198.51.100.${Math.floor(Math.random()*200)+1}`});
 const body = await response.json() as {entitled?:boolean;entitlementToken?:string}; expect(body.entitled).toBe(true); return body.entitlementToken!;
}
async function signing() { const key = await crypto.subtle.generateKey({name:"ECDSA",namedCurve:"P-256"},true,["sign","verify"]) as CryptoKeyPair;
 return {publicKey:base64Encode(new Uint8Array((await crypto.subtle.exportKey("raw",key.publicKey)) as ArrayBuffer)), sign:async(f:string[])=>base64Encode(new Uint8Array(await crypto.subtle.sign({name:"ECDSA",hash:"SHA-256"},key.privateKey,guestCanonical(f) as BufferSource)))}; }
async function agreement() { const key = await crypto.subtle.generateKey({name:"ECDH",namedCurve:"P-256"},true,["deriveBits"]) as CryptoKeyPair; return base64Encode(new Uint8Array((await crypto.subtle.exportKey("raw",key.publicKey)) as ArrayBuffer)); }
describe("production guest adapters", () => {
 it("serves inert CSP page and rejects cross-origin, query and native browser upgrades",async()=>{
  const page = await SELF.fetch("https://farside.test/guest"); expect(page.status).toBe(200); expect(page.headers.get("cache-control")).toBe("no-store"); expect(page.headers.get("permissions-policy")).toContain("microphone=()");
  expect(page.headers.get("content-security-policy")).toContain("frame-ancestors 'none'"); expect(await page.text()).not.toContain("entitlementToken");
  expect((await SELF.fetch("https://farside.test/guest-signal",{headers:{upgrade:"websocket",origin:"https://other.test"}})).status).toBe(404);
  expect((await SELF.fetch("https://farside.test/guest-signal?room=secret",{headers:{upgrade:"websocket",origin:"https://farside.test"}})).status).toBe(404);
  expect((await SELF.fetch("https://farside.test/signal",{headers:{upgrade:"websocket",origin:"https://farside.test"}})).status).toBe(403);
 });
 it("refuses local/free guest admission without evicting native owner",async()=>{
  const p = await pairing(), host = await connectHost(p,{features:["route.1","renew.1","guest-v1"]}), phone = await connectClient(p,{features:["route.1","renew.1"]});
  expect(host.registered.features).toEqual(["guest-v1"]); await host.next(); await phone.next(); await host.next(); await phone.next();
  const guest = await open("/guest-signal",{origin:"https://farside.test"});
  guest.send({type:"guestRequest",version:1,room:p.room,grantID:randomHex(),secret:randomHex(),publicKey:(await signing()).publicKey,agreementKey:await agreement(),nonce:randomHex(),signature:"bad",origin:"https://farside.test"});
  expect((await guest.closed).reason).toBeTruthy(); host.send({type:"renew"}); expect((await host.next()).type).toBe("route"); expect((await phone.next()).type).toBe("route"); expect((await host.next()).type).toBe("renewed"); host.close(); phone.close();
 });
 it.each([false, true, "cold"] as const)("binds paid owner/approval and fences delayed provider issuance (retire=%s)",async(staleProvider)=>{
  turn.reset(); const p = await pairing(), host = await connectHost(p,{features:["route.1","renew.1","guest-v1"]});
  const phone = await connectClient(p,{features:["route.1","renew.1","remote.1"],entitlement:await paidToken()});
  expect((await host.next()).type).toBe("ice"); const route = await host.next(); expect(route.access).toBe("remote"); await phone.next(); await host.next(); await phone.next();
  const baseline = turn.generateCalls, hostKey = await signing(), recipient = await signing(), recipientAgreement = await agreement();
  const grantID = randomHex(), hostID = randomHex(), ownerSessionID = randomHex(), secret = randomHex(), nonce = randomHex(), origin = "https://farside.test";
  host.send({type:"guest",version:1,guest:{operation:"invite",grantID,hostID,ownerSessionID,scopeEpoch:"1",geometryEpoch:"2",scopeKind:"window",mode:"view",origin,publicKey:hostKey.publicKey,inviteHash:await sha256Hex(secret),expiresAt:Date.now()+120000}});
  expect((await host.next()).guest).toMatchObject({operation:"created",grantID});
  const guest = await open("/guest-signal",{origin}); guest.send({type:"guestRequest",version:1,room:p.room,grantID,secret,publicKey:recipient.publicKey,agreementKey:recipientAgreement,nonce,signature:await recipient.sign(["request",origin,p.room,grantID,recipient.publicKey,recipientAgreement,nonce]),origin});
  const pending = (await host.next()).guest as {requestID:string}; expect(pending).toMatchObject({operation:"pending",grantID}); expect(turn.generateCalls).toBe(baseline);
  const ticket = randomHex(), now = Date.now();
  const grant: GuestGrant = {version:1,hostID,grantID,ownerSessionID,scopeEpoch:"1",geometryEpoch:"2",scopeKind:"window",mode:"view",origin,requestID:pending.requestID,recipientPublicKey:recipient.publicKey,recipientAgreementKey:recipientAgreement,hostAgreementKey:await agreement(),recipientNonce:nonce,hostNonce:randomHex(),issuedAt:now,expiresAt:now+600000,ticketHash:await sha256Hex(ticket)};
  host.send({type:"guest",version:1,guest:{operation:"approve",grantID,requestID:pending.requestID,grant,ticket,signature:await hostKey.sign(grantFields(grant))}});
  const approved = (await guest.next()).guest as {sessionID:string}; expect(approved).toMatchObject({operation:"approved",grant,ticket});
  const release = staleProvider === true ? turn.holdGenerate() : undefined;
  guest.send({type:"guest",version:1,guest:{operation:"redeem",grantID,ticket,sessionID:approved.sessionID,signature:await recipient.sign(["redeem",ticket,approved.sessionID,grant.hostNonce])}});
  if (staleProvider === true) {
   const deadline = Date.now()+3000; while (turn.generateCalls !== baseline+1 && Date.now()<deadline) await sleep(5);
   expect(turn.generateCalls).toBe(baseline+1); host.close(); expect((await guest.closed).reason).toBeTruthy();
   release!(); await sleep(50); expect(turn.revokeCalls).toBeGreaterThan(0); phone.close(); return;
  }
  const ready = (await guest.next()).guest; expect(ready).toMatchObject({operation:"ready",grantID,sessionID:approved.sessionID}); expect((await host.next()).guest).toEqual(ready); expect(turn.generateCalls).toBe(baseline+1);
  const proofNonce = randomHex();
  host.send({type:"guest",version:1,guest:{operation:"check",grantID,sessionID:approved.sessionID,nonce:proofNonce}});
  expect((await host.next()).guest).toEqual({operation:"alive",grantID,sessionID:approved.sessionID,nonce:proofNonce,expiresAt:grant.expiresAt});
  if (staleProvider === "cold") {
   const rooms = testEnv.ROOM as unknown as DurableObjectNamespace<RoomDO>;
   await evictDurableObject(rooms.get(rooms.idFromName(p.room)));
   phone.send({type:"signal",payload:payload64(4)});
   const reset = (await host.next()).guest as {operation:string;code:string;nonce:string};
   expect(reset).toMatchObject({operation:"serviceReset",code:route.epoch});
   expect(Object.keys(reset).sort()).toEqual(["code","nonce","operation"]); expect(reset.nonce).toMatch(/^[a-f0-9]{64}$/);
   expect((await host.next()).payload).toBe(payload64(4));
   expect((await guest.closed).reason).toBe("fresh_guest_approval_required");
   await sleep(50); expect(turn.revoked).toEqual([turn.issued[baseline]]);
   host.send({type:"renew"}); expect((await host.next()).type).toBe("route"); expect((await phone.next()).type).toBe("route"); expect((await host.next()).type).toBe("renewed");
  }
  host.close(); expect((await guest.closed).reason).toBeTruthy(); await sleep(50); expect(turn.revokeCalls).toBeGreaterThan(0); phone.close();
 });
});
