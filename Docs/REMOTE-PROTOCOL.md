# PocketDesk remote prototype contract v1

**Engineering draft, subordinate to [PRODUCT.md](../PRODUCT.md).** Private feasibility implementation is active. Existing protocol choices remain subject to live validation; this file is not a second product specification.

User decision: built-in away-from-home access, iPhone 17 and M4 MacBook Air, awake/unlocked host acceptable during prototype. WebRTC provides media, ICE/STUN/TURN and reliable ordered data channels. WSS signaling is a rendezvous path, not authority to view/control. No Tailscale dependency. Native app uses normal system TLS verification and rejects insecure non-loopback signaling URLs.

## Signaling routing

JSON, version 1. WSS `/signal`, TLS terminated by deployment reverse proxy. Local development binds 127.0.0.1; ws is allowed only for localhost/127.0.0.1/[::1]. No credential in query strings. Max record 256 KiB; no compression; bounded sends. First record within five seconds:

Host: `{ "type":"register", "version":1, "role":"host", "room":"<64 lowercase hex SHA256(hostToken UTF8)>", "token":"<64 lowercase hex random 256-bit hostToken>", "clientTokenHash":"<64 lowercase hex SHA256(clientToken UTF8)>" }`

Client: same fields with `role:"client"`, token is clientToken, no clientTokenHash. Server checks host room hash, holds clientTokenHash while host online, compares client digest before admission. Only one host/client socket per room; duplicates do not evict existing peers. Unknown/offline host fails. Host reconnect registers anew. Server stores hashes only and does not log messages/tokens. This authenticates routing, NOT screen access.

Server response `{ "type":"registered", "role":"host|client" }`, then optional `{ "type":"ice", "servers":[{"urls":["turn:..."],"username":"...","credential":"..."}] }`. Configured TURN credentials come from the selected Cloudflare API adapter or coturn shared-secret adapter, expire, and never expose the long-lived issuer secret to apps. No configured TURN means direct-only test coverage, not reliable public connectivity.

Peer state `{ "type":"peer", "online":true|false }`. Both peers are notified when counterpart joins. Host disconnect closes its client. Client disconnect notifies host and keeps host registration. Client-to-server `{ "type":"signal", "payload":"<base64 opaque sealed bytes>" }` forwards only to authenticated counterpart in that room. Error `{ "type":"error", "code":"..." }` with sanitized reason. No SDP, ICE, remote input or video parsed by signaling service.

## Endpoint authentication and session binding

Pairing must authenticate WebRTC negotiation end to end; TLS/DTLS alone does not protect against a malicious signaling service substituting SDP. Native peers protect signaling payloads with CryptoKit AES-GCM using a random per-pair key never sent to the signaling service. The complete SDP including DTLS fingerprints and all ICE candidates are inside authenticated payloads. Reject tampered messages. Fresh client request and host challenge nonces bind every negotiation; only a response to the current challenge can start a session. Messages carry session ID and sequence; reject duplicates, old sessions, unexpected message types and oversized plaintexts. Local host authorization precedes initial pairing/capture/input. Pairing persists in device-only Keychain, is revocable, and must not put reusable credentials in logs.

WebRTC input travels on one reliable ordered `control` data channel. Every message has version/session/sequence; pointer events include geometry epoch. Explicit button down/up and releaseAll are idempotent. A two-second host held-input lease is renewed only by accepted drag/move activity, never by heartbeats; expiry releases the hold and tells the phone to reset drag state. No queued clicks or text replay after reconnection. Capture begins only after endpoint authentication and authorized host content selection. Video never gates input on a per-frame acknowledgement.

This freezes server routing now. Native enrollment/session/input schemas must be finalized and tested before screen/input authorization; the paragraphs above are requirements, not a claim of completed implementation. This protocol supersedes the attachment's LAN-only transport proposal for the current user-selected goal.

## Implemented private control envelope

`ControlPacket` contains version 1, fresh session ID, monotonically increasing sequence, and `RemoteAction`. The host sends `geometry` with logical width/height in x/y and a new epoch before `viewing`. Phone user actions carry that epoch; the host rejects stale epochs. Release is always accepted. Display changes end the session instead of silently retargeting input.

`capture` x=1/0 reports source health. Only fresh complete/idle ScreenCaptureKit status permits retransmitting the last frame; retransmission itself never refreshes capture health. Phone input requires both frame freshness and capture health. Live idle-status cadence remains a manual test.

`text` uses a request ID in key (at most 32 UTF-8 bytes), with payload bounded by both 4096 UTF-8 bytes and 1024 UTF-16 units. `textResult` echoes key and x=1 if input was accepted for OS injection or x=0 if refused. This is not proof an application used the text. The phone retains its draft until the matching receipt and never automatically retries uncertain text.

For first enrollment, the host saves rotated trust before sending it to the approved phone. The old invitation is not a recovery credential. An interrupted enrollment that fails to save the new phone trust requires a fresh pairing code beside the Mac. Existing sessions protect negotiation with the original cipher until they finish; reconnect uses rotated credentials.

The relay-only option restricts ICE policy to TURN. Diagnostic route/codec/fps/network RTT comes from WebRTC statistics; network RTT is not physical input-to-visible latency. Test receipts distinguish generated media from real ScreenCaptureKit capture.
# Browser v1 implementation contract — 13 September 2026

This separate namespace preserves native pairing and `/signal`. Initial service binds loopback only. HTTPS/private proxy support must preserve exact Origin and Host checks; public deployment is paused.

## Canonical browser crypto

`BrowserCrypto.canonical(fields)` is UTF-8 `PocketDesk/browser/1` followed by each UTF-8 string field, each prefixed with its unsigned 32-bit big-endian byte length (the domain is prefixed too). No JSON canonicalization. P-256 signing public keys are 65-byte raw X9.63, signatures 64-byte P1363; binary values use standard padded base64. IDs/nonces/tokens are 32 random bytes represented as 64 lowercase hex characters. Times/revisions/sequences are canonical nonnegative decimal strings (at most JavaScript safe integer). Signed fields have fixed order; no optional fields.

Enrollment offer `pocketdesk-browser:` + base64 JSON contains `{version:1,url,hostID,hostKey,secret,expires}`. It is created explicitly on the Mac, valid 120 seconds, and is pasted into an inert browser field, never a URL. Browser creates a non-extractable P256 signing key in IndexedDB. Enrollment POST carries only `{nonce,payload}`: nonce is 12 random bytes, payload is AES-256-GCM ciphertext plus 16-byte tag for UTF8 JSON `{peerID,publicKey}`. The AES key is the offer's 32-byte random secret (hex decoded); AAD is canonical `["enroll",hostID,origin]`. The secret is never sent through the relay. Mac decrypts using its live offer and validates all fields before approval. Browser requires offer origin to exactly match its trusted viewer origin. Mac requires explicit approval (synthetic harness may explicitly auto-approve invented content only), consumes the offer, and stores a separate BrowserPeer. Response `{receipt,signature}` signs fields `["enrolled",hostID,peerID,publicKey,origin,mode,display]`. Browser pins offer hostKey before accepting receipt. Separate Keychain namespace for host signing identity and browser peers; no native pair mutation.

Challenge POST `{peerID,nonce,mode}`. Mac returns `{fields,signature}` signing exactly `["challenge",hostID,peerID,origin,mode,display,revision,session,expires,nonce,hostNonce,hostEphemeralPublicKey]`. Challenge lasts 30 seconds; fresh P256 ECDH ephemeral key each time. Browser validates all pinned/request fields, then proof POST `{session,publicKey,signature}` where publicKey is its new ephemeral key and signature signs `["proof",SHA256(canonical(challengeFields)),publicKey]`. Mac atomically consumes the pending challenge before accepting proof. One active/pending browser session, reject busy; do not evict native sessions.

Both endpoints derive AES256 key from ECDH using HKDF-SHA256, salt SHA256(canonical(challengeFields)), info UTF8 `PocketDesk/browser/1/signaling`. Host response `{ticket,session,expires,signature}` signs `["ticket",session,ticket,expires,challengeHash]`; expires is ticket deadline (15 seconds). Before responding the host installs `{type:"ticket",ticket,session,expires,peerID}` into its authenticated service connection. Service retains only ticket SHA256; consumes atomically on first redemption. Session maximum 10 minutes is enforced independently by Mac. Expiry/Stop/revoke clear challenge, ticket and media.

## Service transport

Dedicated `createBrowserService` runs independently of native createService. Host WSS `/browser-host` rejects Origin, first message `{type:"host",hostID,token}` where SHA256(token)==hostID; bounded peers and registration timeout. Browser HTTP `POST /browser-api/<hostID>/<enroll|challenge|proof>` checks exact configured Origin/Host and JSON/size, forwards `{type:"request",id,operation,body}` to the authenticated host. Host replies `{type:"response",id,body}` or `{type:"response",id,error}`. Enrollment requests last up to 120 seconds for human approval; challenge/proof requests last five seconds. Timeout or HTTP cancellation sends `{type:"cancel",id}` to the host; only matching pending authority is cleared. Late authenticated responses are ignored after cancellation, rather than disconnecting the host. Requests also cancel when the host/socket stops. GET is static/inert. No endpoint mints credentials on GET.

Browser WSS `/browser-signal` checks exact Origin, receives only `{type:"browser",hostID,session,ticket}` before admission. Service consumes ticket before attaching one browser, sends host `{type:"joined",session}`, browser `{type:"registered",session}`. Host/browser relay `{type:"signal",session,envelope}` only in attached session. End `{type:"end",session}` closes that session; host Stop/disconnect invalidates all pending transport authority. Service never sends ICE/session payload before authentication. Native routes remain unchanged.

Envelope `{sequence,direction,payload}` contains base64 AESGCM ciphertext+tag. Sequence starts at 1 and strictly increases, direction `host` or `browser`. Nonce UInt32BE(1 host/2 browser)+UInt64BE(sequence); AAD canonical `["signal",session,direction,sequence,challengeHash]`. Decrypted UTF8 JSON is MediaSignal. First browser signal is `{kind:"ready"}` for key confirmation; host then offers. Offer/answer SDP and ICE are all encrypted/authenticated. DTLS fingerprint in authenticated SDP binds media. The established ordered binary `control` channel receives a first `{type:"bind",session,challengeHash}` packet; its DTLS identity is already bound by authenticated SDP. No input before this binding.

## Control and displayed-frame proof

Separate binary UTF8 JSON `{type:"input",session,sequence,revision,frameToken,action}`; action follows RemoteAction bounds. OS actions require interactive grant, separate Mac consent, current Accessibility, current capture health and revision, strict input sequence, plus a known per-frame token no more than 600ms old by host monotonic time. Token is carried only in pixels, never status messages. Release bypasses freshness/scope to release only this session's held input. Unknown/malformed/replayed input closes or rejects and releases held state. Text acknowledgements retain existing explicit result semantics. On source/capture-health change clear token ring and release. Existing native input is unchanged.

Footer marker: append 48 pixels below content; bottom-right 88x48 matrix, quiet 4px border, 20x10 cells each 4px. Row-major: fixed sync 0x50444231 (32 bits), version 1 (8 bits), random token (128 bits), CRC32C(version byte+token bytes) (32 bits). Browser reads intrinsic decoded pixels in requestVideoFrameCallback. Host stores token+revision+monotonic time in a 128-entry ring. Compression damage blocks input. This establishes a conservative frame delivery/decode/return bound, not human attention or exact latency. Footer must not cover source content. Browser metadata remains diagnostics, not freshness authority.

Current physical Safari/Chrome, native-to-browser marker survivability, real capture/input and public TURN gates are unvalidated. Contract receives independent review before real access.


### Browser-code delivery trust boundary

Enrollment encryption prevents an untrusted **forwarding path** from substituting the browser key when the user runs the trusted viewer. It cannot protect a secret typed into malicious JavaScript. This local feasibility process serves both static viewer files and signaling, so the local code and its delivery are trusted. A compromised static-content origin can replace the client and defeats browser confidentiality/control regardless of transport crypto. Public G4 remains blocked pending an independently reviewed trusted static-delivery and signaling-origin design; these local passes do not close that deployment threat. No public service is authorized by this checkpoint.
