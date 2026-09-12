# PocketDesk remote prototype contract v1

User decision: built-in away-from-home access, iPhone 17 and M4 MacBook Air, awake/unlocked host acceptable during prototype. WebRTC provides media, ICE/STUN/TURN and reliable ordered data channels. WSS signaling is a rendezvous path, not authority to view/control. No Tailscale dependency. Native app uses normal system TLS verification and rejects insecure non-loopback signaling URLs.

## Signaling routing

JSON, version 1. WSS `/signal`, TLS terminated by deployment reverse proxy. Local development binds 127.0.0.1; ws is allowed only for localhost/127.0.0.1/[::1]. No credential in query strings. Max record 256 KiB; no compression; bounded sends. First record within five seconds:

Host: `{ "type":"register", "version":1, "role":"host", "room":"<64 lowercase hex SHA256(hostToken UTF8)>", "token":"<64 lowercase hex random 256-bit hostToken>", "clientTokenHash":"<64 lowercase hex SHA256(clientToken UTF8)>" }`

Client: same fields with `role:"client"`, token is clientToken, no clientTokenHash. Server checks host room hash, holds clientTokenHash while host online, compares client digest before admission. Only one host/client socket per room; duplicates do not evict existing peers. Unknown/offline host fails. Host reconnect registers anew. Server stores hashes only and does not log messages/tokens. This authenticates routing, NOT screen access.

Server response `{ "type":"registered", "role":"host|client" }`, then optional `{ "type":"ice", "servers":[{"urls":["turn:..."],"username":"...","credential":"..."}] }`. Configured TURN credentials are short-lived HMAC credentials from server environment, never a shared TURN secret in apps. No configured TURN means direct-only test coverage, not reliable public connectivity.

Peer state `{ "type":"peer", "online":true|false }`. Both peers are notified when counterpart joins. Host disconnect closes its client. Client disconnect notifies host and keeps host registration. Client-to-server `{ "type":"signal", "payload":"<base64 opaque sealed bytes>" }` forwards only to authenticated counterpart in that room. Error `{ "type":"error", "code":"..." }` with sanitized reason. No SDP, ICE, remote input or video parsed by signaling service.

## Endpoint authentication and session binding

Pairing must authenticate WebRTC negotiation end to end; TLS/DTLS alone does not protect against a malicious signaling service substituting SDP. Native peers protect signaling payloads with CryptoKit AES-GCM using a random per-pair key never sent to the signaling service. The complete SDP including DTLS fingerprints and all ICE candidates are inside authenticated payloads. Reject tampered messages. Fresh client request and host challenge nonces bind every negotiation; only a response to the current challenge can start a session. Messages carry session ID and sequence; reject duplicates, old sessions, unexpected message types and oversized plaintexts. Local host authorization precedes initial pairing/capture/input. Pairing persists in device-only Keychain, is revocable, and must not put reusable credentials in logs.

WebRTC input travels on one reliable ordered `control` data channel. Every message has version/session/sequence; pointer events include geometry epoch. Explicit button down/up and releaseAll are idempotent. A two-second host input lease is renewed by authenticated control heartbeats; interruption releases remote holds. No queued clicks or text replay after reconnection. Capture begins only after endpoint authentication and authorized host content selection. Video never gates input on a per-frame acknowledgement.

This freezes server routing now. Native enrollment/session/input schemas must be finalized and tested before screen/input authorization; the paragraphs above are requirements, not a claim of completed implementation. This protocol supersedes the attachment's LAN-only transport proposal for the current user-selected goal.
