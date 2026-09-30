export const guestHTML = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Farside guest viewing</title><script src="/guest.js" defer></script></head><body><main><h1>Guest viewing</h1><p>Video only. No audio, control, files or clipboard. Your Mac owner must approve your recipient key. Viewing ends when the session or shared content changes. Pixels already received may be recorded.</p><button id="connect">Connect and request approval</button><button id="end" disabled>End viewing</button><p id="status" role="status">Preparing link…</p><p id="fingerprint"></p><video id="video" autoplay muted playsinline aria-label="Shared Mac content, video only" style="max-width:100%;background:black"></video></main></body></html>`;
export const guestJavaScript = String.raw`"use strict";
(() => {
const el = id => document.getElementById(id), status = el("status"), video = el("video"), connect = el("connect"), endButton = el("end"), encoder = new TextEncoder(), MAX = 9007199254740991n;
let link, socket, peer, signing, agreement, recipientKey, recipientAgreement, nonce, grant, sessionID, key, expiry;
let sent = 0n, received = 0n, ended = false, started = false, pending = 0, outgoing = Promise.resolve(), incoming = Promise.resolve(), candidates = [];
const token = v => typeof v === "string" && /^[a-f0-9]{64}$/.test(v);
const epoch = v => typeof v === "string" && /^[1-9][0-9]{0,19}$/.test(v) && BigInt(v) <= 18446744073709551615n;
const encode = bytes => btoa(Array.from(bytes, n => String.fromCharCode(n)).join(""));
const decode = text => { if (typeof text !== "string" || text.length > 174784) throw Error(); const b = Uint8Array.from(atob(text), c => c.charCodeAt(0)); if (encode(b) !== text) throw Error(); return b; };
const keyValid = v => { try { const b = decode(v); return b.length === 65 && b[0] === 4; } catch { return false; } };
const canonical = fields => { const parts = ["Farside/guest/1", ...fields].map(v => encoder.encode(v)); const out = new Uint8Array(parts.reduce((n,p) => n+4+p.length,0)); let offset = 0; for (const p of parts) { new DataView(out.buffer).setUint32(offset,p.length); out.set(p,offset+4); offset += 4+p.length; } return out; };
const hash = async bytes => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",bytes)), n => n.toString(16).padStart(2,"0")).join("");
const random = () => Array.from(crypto.getRandomValues(new Uint8Array(32)), n => n.toString(16).padStart(2,"0")).join("");
const fields = g => ["grant",g.origin,g.hostID,g.grantID,g.ownerSessionID,g.scopeEpoch,g.geometryEpoch,g.scopeKind,g.mode,g.requestID,g.recipientPublicKey,g.recipientAgreementKey,g.hostAgreementKey,g.recipientNonce,g.hostNonce,String(g.issuedAt),String(g.expiresAt),g.ticketHash];
function clear(message) {
 if (ended) return; ended = true; clearTimeout(expiry); status.textContent = message; connect.disabled = true; endButton.disabled = true;
 if (peer) { for (const r of peer.getReceivers()) r.track && r.track.stop(); peer.close(); peer = null; }
 if (video.srcObject) for (const t of video.srcObject.getTracks()) t.stop(); video.srcObject = null;
 if (socket) { socket.onclose = null; socket.close(); socket = null; }
 candidates = []; key = null; signing = null; agreement = null; link = null;
}
function send(value) { if (ended || !socket || socket.readyState !== WebSocket.OPEN || socket.bufferedAmount > 131072) throw Error(); socket.send(JSON.stringify(value)); }
const sign = async f => encode(new Uint8Array(await crypto.subtle.sign({name:"ECDSA",hash:"SHA-256"},signing.privateKey,canonical(f))));
function parameters(direction,n) {
 if (n <= 0n || n > MAX) throw Error(); const iv = new Uint8Array(12), v = new DataView(iv.buffer); v.setUint32(0,direction === "host" ? 1 : 2); v.setBigUint64(4,n);
 return {name:"AES-GCM",iv,additionalData:canonical(["signal",grant.grantID,sessionID,direction,String(n)]),tagLength:128};
}
function signal(value) {
 if (++pending > 32) { clear("Signaling backlog ended viewing."); return; }
 outgoing = outgoing.then(async () => { if (ended) return; const bytes = encoder.encode(JSON.stringify(value)); if (bytes.length > 131072) throw Error(); const n = ++sent;
  const payload = encode(new Uint8Array(await crypto.subtle.encrypt(parameters("guest",n),key,bytes))); if (ended) return;
  send({type:"guest",version:1,guest:{operation:"signal",grantID:grant.grantID,sessionID,envelope:{direction:"guest",sequence:String(n),payload}}});
 }).catch(() => clear("Secure signaling failed.")).finally(() => { pending--; });
}
async function approved(f) {
 if (grant || !link) throw Error(); const g = f.grant, now = Date.now();
 const keys = ["version","hostID","grantID","ownerSessionID","scopeEpoch","geometryEpoch","scopeKind","mode","requestID","recipientPublicKey","recipientAgreementKey","hostAgreementKey","recipientNonce","hostNonce","origin","issuedAt","expiresAt","ticketHash"];
 if (!g || Object.keys(g).sort().join() !== keys.sort().join() || g.version !== 1 || g.mode !== "view" || g.origin !== location.origin || g.grantID !== link.grantID || ![g.hostID,g.ownerSessionID,g.requestID,g.hostNonce,g.ticketHash].every(token) || !epoch(g.scopeEpoch) || !epoch(g.geometryEpoch) || !["display","application","window"].includes(g.scopeKind) || g.recipientPublicKey !== recipientKey || g.recipientAgreementKey !== recipientAgreement || g.recipientNonce !== nonce || !keyValid(g.hostAgreementKey) || !Number.isSafeInteger(g.issuedAt) || !Number.isSafeInteger(g.expiresAt) || g.issuedAt <= 0 || g.issuedAt > now || g.expiresAt <= now || g.expiresAt-g.issuedAt > 600000 || !token(f.ticket) || !token(f.sessionID) || await hash(encoder.encode(f.ticket)) !== g.ticketHash) throw Error();
 const publicKey = await crypto.subtle.importKey("raw",decode(link.publicKey),{name:"ECDSA",namedCurve:"P-256"},false,["verify"]), signature = decode(f.signature);
 if (signature.length !== 64 || !await crypto.subtle.verify({name:"ECDSA",hash:"SHA-256"},publicKey,signature,canonical(fields(g))) || await hash(canonical(fields(g))) !== f.sessionID) throw Error();
 const other = await crypto.subtle.importKey("raw",decode(g.hostAgreementKey),{name:"ECDH",namedCurve:"P-256"},false,[]);
 const bits = await crypto.subtle.deriveBits({name:"ECDH",public:other},agreement.privateKey,256), hkdf = await crypto.subtle.importKey("raw",bits,"HKDF",false,["deriveKey"]);
 const derived = await crypto.subtle.deriveKey({name:"HKDF",hash:"SHA-256",salt:await crypto.subtle.digest("SHA-256",canonical(fields(g))),info:encoder.encode("Farside/guest/1/signaling")},hkdf,{name:"AES-GCM",length:256},false,["encrypt","decrypt"]);
 if (ended || g.expiresAt <= Date.now()) return;
 grant = g; sessionID = f.sessionID; key = derived; clearTimeout(expiry); expiry = setTimeout(() => clear("Guest viewing expired."),Math.max(0,Math.min(600000,g.expiresAt-now)));
 const signatureRedeem = await sign(["redeem",f.ticket,sessionID,g.hostNonce]);
 send({type:"guest",version:1,guest:{operation:"redeem",grantID:g.grantID,ticket:f.ticket,sessionID,signature:signatureRedeem}});
 status.textContent = "Approved for shared " + g.scopeKind + ". Video only; audio off.";
}
async function ready(f) {
 if (!grant || peer || f.grantID !== grant.grantID || f.sessionID !== sessionID || f.expiresAt !== grant.expiresAt || !Array.isArray(f.servers) || !f.servers.length || f.servers.length > 8 || !f.servers.every(s => Array.isArray(s.urls) && s.urls.length > 0 && s.urls.length <= 8 && s.urls.every(u => typeof u === "string" && u.length <= 2048 && /^(stun|turn|turns):/.test(u)))) throw Error();
 if (ended) return; peer = new RTCPeerConnection({iceServers:f.servers,bundlePolicy:"max-bundle"});
 peer.onicecandidate = e => { if (e.candidate && !ended) signal({kind:"candidate",candidate:e.candidate.candidate,mid:e.candidate.sdpMid,line:e.candidate.sdpMLineIndex}); };
 peer.ondatachannel = e => { e.channel.close(); clear("Unexpected data channel ended viewing."); };
 peer.ontrack = e => { if (ended || e.track.kind !== "video") { e.track.stop(); if (!ended) clear("Unexpected media ended viewing."); return; } video.srcObject = new MediaStream([e.track]); video.play().catch(() => {}); };
 peer.onconnectionstatechange = () => { if (peer && ["failed","disconnected","closed"].includes(peer.connectionState)) clear("Guest media ended."); };
}
async function media(f) {
 if (!peer || !grant || f.grantID !== grant.grantID || f.sessionID !== sessionID || !f.envelope) throw Error(); const e = f.envelope;
 if (e.direction !== "host" || typeof e.sequence !== "string" || !/^[1-9][0-9]{0,15}$/.test(e.sequence)) throw Error(); const n = BigInt(e.sequence); if (n <= received || n > MAX) throw Error();
 const bytes = await crypto.subtle.decrypt(parameters("host",n),key,decode(e.payload)); if (bytes.byteLength > 131072) throw Error(); if (ended || grant.expiresAt <= Date.now()) return;
 const m = JSON.parse(new TextDecoder("utf-8",{fatal:true}).decode(bytes)); received = n;
 if (m.kind === "offer") {
  if (peer.remoteDescription || typeof m.sdp !== "string" || m.sdp.length > 98304 || /m=(audio|application)/.test(m.sdp) || m.sdp.split("m=video").length !== 2 || !m.sdp.includes("a=sendonly") || !m.sdp.includes("a=fingerprint:")) throw Error();
  await peer.setRemoteDescription({type:"offer",sdp:m.sdp}); if (ended) return;
  for (const c of candidates) await peer.addIceCandidate(c); candidates = [];
  const answer = await peer.createAnswer(); if (ended) return; if (/m=(audio|application)/.test(answer.sdp) || !answer.sdp.includes("a=recvonly")) throw Error();
  await peer.setLocalDescription(answer); if (!ended) signal({kind:"answer",sdp:answer.sdp});
 } else if (m.kind === "candidate" && typeof m.candidate === "string" && m.candidate.length <= 8192 && Number.isInteger(m.line) && m.line >= 0 && m.line <= 16 && (m.mid == null || typeof m.mid === "string" && m.mid.length <= 32)) {
  const c = {candidate:m.candidate,sdpMLineIndex:m.line,sdpMid:m.mid}; if (peer.remoteDescription) await peer.addIceCandidate(c); else if (candidates.length < 64) candidates.push(c); else throw Error();
 } else throw Error();
}
async function receive(raw) {
 if (ended) return; if (typeof raw !== "string" || raw.length > 262144) throw Error(); const packet = JSON.parse(raw);
 if (packet.type !== "guest" || packet.version !== 1 || !packet.guest) throw Error(); const f = packet.guest;
 if (f.operation === "approved") await approved(f); else if (f.operation === "ready") await ready(f); else if (f.operation === "signal") await media(f); else if (f.operation === "ended") clear("The owner ended viewing."); else throw Error();
}
connect.addEventListener("click",async () => {
 if (started || ended || !link) return; started = true; connect.disabled = true; endButton.disabled = false;
 try {
  if (link.expiresAt <= Date.now()) throw Error();
  signing = await crypto.subtle.generateKey({name:"ECDSA",namedCurve:"P-256"},false,["sign","verify"]); agreement = await crypto.subtle.generateKey({name:"ECDH",namedCurve:"P-256"},false,["deriveBits"]);
  recipientKey = encode(new Uint8Array(await crypto.subtle.exportKey("raw",signing.publicKey))); recipientAgreement = encode(new Uint8Array(await crypto.subtle.exportKey("raw",agreement.publicKey))); nonce = random();
  const signature = await sign(["request",location.origin,link.room,link.grantID,recipientKey,recipientAgreement,nonce]); if (ended) return;
  el("fingerprint").textContent = "Your recipient key fingerprint: " + await hash(decode(recipientKey)); status.textContent = "Waiting for owner approval. Verify this full fingerprint through a trusted channel.";
  socket = new WebSocket((location.protocol === "https:" ? "wss:" : "ws:")+"//"+location.host+"/guest-signal");
  socket.onopen = () => { try { send({type:"guestRequest",version:1,room:link.room,grantID:link.grantID,secret:link.secret,publicKey:recipientKey,agreementKey:recipientAgreement,nonce,signature,origin:location.origin}); } catch { clear("Guest request failed."); } };
  let backlog = 0; socket.onmessage = e => { if (++backlog > 32) { clear("Message backlog ended viewing."); return; } incoming = incoming.then(() => receive(e.data)).catch(() => clear("Guest authorization or secure media failed.")).finally(() => { backlog--; }); };
  socket.onclose = () => clear("Viewing ended. Ask the owner for a fresh link."); socket.onerror = () => clear("Guest service unavailable.");
  expiry = setTimeout(() => { if (!grant) clear("Approval link expired."); },Math.max(0,link.expiresAt-Date.now()));
 } catch { clear("Guest viewing could not start."); }
});
endButton.addEventListener("click",() => clear("Guest viewing ended."));
document.addEventListener("visibilitychange",() => { if (document.visibilityState !== "visible") clear("Viewing ended when this page left the foreground."); });
window.addEventListener("pagehide",() => clear("Guest viewing ended."));
try {
 const fragment = location.hash.slice(1); history.replaceState(null,"",location.pathname); if (!isSecureContext || fragment.length > 4096 || !/^[A-Za-z0-9_-]+$/.test(fragment)) throw Error();
 const text = fragment.replace(/-/g,"+").replace(/_/g,"/"); link = JSON.parse(new TextDecoder("utf-8",{fatal:true}).decode(Uint8Array.from(atob(text+"=".repeat((4-text.length%4)%4)), c => c.charCodeAt(0))));
 if (link.version !== 1 || ![link.room,link.grantID,link.secret].every(token) || !keyValid(link.publicKey) || !Number.isSafeInteger(link.expiresAt) || link.expiresAt <= Date.now() || link.expiresAt-Date.now() > 120000) throw Error();
 status.textContent = "Ready. Connect generates a fresh recipient key and asks the owner for approval.";
} catch { clear("Invalid or expired guest link. Ask the Mac owner for a fresh link."); }
})();`;
export function guestPage(request: Request): Response {
 const url = new URL(request.url), script = url.pathname === "/guest.js";
 const websocketOrigin = url.origin.replace(/^https:/, "wss:").replace(/^http:/, "ws:");
 return new Response(request.method === "HEAD" ? null : script ? guestJavaScript : guestHTML, {headers:{
 "content-type":script ? "text/javascript; charset=utf-8" : "text/html; charset=utf-8",
 "content-security-policy":`default-src 'none'; script-src 'self'; connect-src 'self' ${websocketOrigin}; media-src 'self' blob:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
 "permissions-policy":"camera=(), microphone=(), display-capture=(), geolocation=()", "x-content-type-options":"nosniff", "referrer-policy":"no-referrer", "cache-control":"no-store"
 }});
}
