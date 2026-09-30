import { expect, test } from "bun:test";
import vm from "node:vm";
import { guestJavaScript } from "../../Backend/src/guest-page";
import { guestCanonical, grantFields, type GuestGrant } from "../../Backend/src/guest";
import { base64Encode, randomHex, sha256Hex } from "../../Backend/src/util";
async function fixture(expired = false) {
 const signing = await crypto.subtle.generateKey({name:"ECDSA",namedCurve:"P-256"},true,["sign","verify"]);
 const publicKey = base64Encode(new Uint8Array(await crypto.subtle.exportKey("raw",signing.publicKey)));
 const link = {version:1,room:randomHex(),grantID:randomHex(),secret:randomHex(),publicKey,expiresAt:Date.now()+(expired ? -1 : 120000)};
 const elements = new Map<string, any>();
 const element = (id: string) => { if (!elements.has(id)) elements.set(id,{textContent:"",disabled:false,srcObject:null,handlers:{},addEventListener(event:string,f:any){this.handlers[event]=f;},play:async()=>{}}); return elements.get(id); };
 const sockets: any[] = [], history: any[] = [], docHandlers: any = {};
 class Socket {
  static OPEN = 1; readyState=1; bufferedAmount=0; messages:any[]=[]; onopen:any; onmessage:any; onclose:any; onerror:any;
  constructor(readonly url:string){sockets.push(this);}
  send(text:string){this.messages.push(JSON.parse(text));}
  close(){this.readyState=3;}
 }
 const document = {visibilityState:"visible",getElementById:element,addEventListener:(event:string,f:any)=>{docHandlers[event]=f;}};
 const fragment = Buffer.from(JSON.stringify(link)).toString("base64url");
 vm.runInNewContext(guestJavaScript,{document,window:{addEventListener:()=>{}},location:{origin:"https://fixture.invalid",host:"fixture.invalid",protocol:"https:",pathname:"/guest",hash:"#"+fragment},history:{replaceState:(...v:any[])=>history.push(v)},isSecureContext:true,crypto,TextEncoder,TextDecoder,URL,Uint8Array,DataView,BigInt,Date,atob,btoa,setTimeout,clearTimeout,WebSocket:Socket});
 async function wait(predicate:()=>boolean) { const deadline=Date.now()+3000; while(!predicate()&&Date.now()<deadline) await Bun.sleep(5); expect(predicate()).toBe(true); }
 async function connect() { await element("connect").handlers.click(); expect(sockets.length).toBe(1); sockets[0].onopen(); return sockets[0].messages[0]; }
 async function approve(request:any, mutate:(g:GuestGrant)=>void = ()=>{}) {
  const agreement = await crypto.subtle.generateKey({name:"ECDH",namedCurve:"P-256"},true,["deriveBits"]);
  const ticket=randomHex(), now=Date.now();
  const grant:GuestGrant={version:1,hostID:randomHex(),grantID:link.grantID,ownerSessionID:randomHex(),scopeEpoch:"1",geometryEpoch:"2",scopeKind:"window",mode:"view",origin:"https://fixture.invalid",requestID:randomHex(),recipientPublicKey:request.publicKey,recipientAgreementKey:request.agreementKey,hostAgreementKey:base64Encode(new Uint8Array(await crypto.subtle.exportKey("raw",agreement.publicKey))),recipientNonce:request.nonce,hostNonce:randomHex(),issuedAt:now,expiresAt:now+600000,ticketHash:await sha256Hex(ticket)};
  const signature = base64Encode(new Uint8Array(await crypto.subtle.sign({name:"ECDSA",hash:"SHA-256"},signing.privateKey,guestCanonical(grantFields(grant)))));
  const sessionID = await sha256Hex(guestCanonical(grantFields(grant))); mutate(grant);
  sockets[0].onmessage({data:JSON.stringify({type:"guest",version:1,guest:{operation:"approved",grant,signature,sessionID,ticket}})});
  return {grant,ticket,sessionID};
 }
 return {link,element,sockets,history,document,docHandlers,wait,connect,approve};
}
test("actual browser script clears URL secret and creates no socket until explicit Connect",async()=>{
 const f=await fixture(); expect(f.history.length).toBe(1); expect(f.history[0][2]).toBe("/guest"); expect(f.sockets.length).toBe(0);
 const request=await f.connect(); expect(request.type).toBe("guestRequest"); expect(request.secret).toBe(f.link.secret); expect(request).not.toHaveProperty("token");
 expect(f.element("fingerprint").textContent).toContain(await sha256Hex(Uint8Array.from(atob(request.publicKey), c=>c.charCodeAt(0))));
 await f.approve(request); await f.wait(()=>f.sockets[0].messages.length===2);
 expect(f.sockets[0].messages[1].guest.operation).toBe("redeem"); expect(f.element("status").textContent).toContain("shared window");
 f.document.visibilityState="hidden"; f.docHandlers.visibilitychange(); expect(f.sockets[0].readyState).toBe(3); expect(f.element("video").srcObject).toBeNull();
});
test("actual script rejects post-signature recipient/scope replacement before redeem or RTC",async()=>{
 const f=await fixture(), request=await f.connect(); await f.approve(request,g=>{g.scopeEpoch="3";});
 await f.wait(()=>f.sockets[0].readyState===3); expect(f.sockets[0].messages.length).toBe(1); expect(f.element("status").textContent).toContain("failed");
});
test("expired link remains inert and cannot request approval",async()=>{
 const f=await fixture(true); expect(f.element("connect").disabled).toBe(true); await f.element("connect").handlers.click(); expect(f.sockets.length).toBe(0); expect(f.element("status").textContent).toContain("expired");
});
