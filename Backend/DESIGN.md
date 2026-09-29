# Farside backend on Cloudflare — design

29 September 2026. Engineering design for launch blocker B1 (production signaling and relay) and the server half of B2 (entitlement gate), subordinate to `PRODUCT.md` (D28, D5). The wire protocol is `Docs/REMOTE-PROTOCOL.md`; the phone-facing entitlement interface is `ENTITLEMENT-CONTRACT.md`. The Bun service in `Server/` stays as the local/dev reference; nothing here changes it or the apps. Current apps work against this service by changing only the service URL.

## 1. Shape

```
phone / Mac ── wss://<host>/signal ──▶ Worker (edge)             POST /v1/entitlements/verify ──▶ Worker ──▶ D1
                    │ reads the first frame (register),           POST /v1/appstore/notifications ─▶ Worker ──▶ D1 ──▶ RoomDO (revoke)
                    │ picks the room, pipes the socket
                    ▼
              RoomDO (one per room, SQLite, hibernating WebSockets)
                    │ issues / revokes short-lived TURN credentials
                    ▼
              Cloudflare Realtime TURN API (key = Worker secret)      media: WebRTC phone ⇄ Mac, via turn.cloudflare.com only when ICE picks relay
```

- **Worker** (`src/index.ts`): routing, per-IP rate limits, input size limits, HTTP APIs, admin, cron. Stateless.
- **RoomDO** (`src/room.ts`): the signaling room, keyed `idFromName(room)` where `room = SHA256(hostToken)` exactly as today. Holds both peers' WebSockets with the Hibernation API (`ctx.acceptWebSocket` + tags `host`/`client`, per-socket attachments), the lease, issued credentials and the entitled flag in its own SQLite storage, one alarm for the lease/auth deadlines.
- **D1** (`migrations/`): entitlements, device links, notification dedupe, room registry, audit. Never on the signaling hot path except one read at phone registration when a token is presented.
- **No Bun, no tunnel, no operator CLI.** Room approval is automatic (§4).

Why the Worker reads the first frame: the apps connect to a fixed `/signal` with no query, header or subprotocol, and send the room only inside the first `register` message (`RemoteShared/SignalingClient.swift`, `PairInvitation.validServer` rejects query strings). A per-room object therefore cannot be chosen at upgrade time. The Worker accepts the socket, waits at most 5 s for one text frame ≤ 200 KiB that parses as `register` with a 64-hex `room`, opens a WebSocket to `ROOM.idFromName(room)` with that frame forwarded, then pipes frames and close codes both ways. The Worker is not billed for wall time; if its isolate is evicted the socket drops and the apps' existing bounded reconnect re-registers (the room object is unaffected). Alternatives rejected: one global object (bottleneck, single region), sharded gateway objects (outbound sockets defeat hibernation and double object duration cost), a protocol change (breaks current apps).

## 2. Protocol mapping (REMOTE-PROTOCOL v1, byte-compatible for old apps)

| Message | Where handled | Behaviour |
|---|---|---|
| `register` host | Worker validates shape → RoomDO | `SHA256(token) == room` (constant-time), `clientTokenHash` hex, one host per room (`already_connected`, no eviction), room not blocked (`room_not_approved`), rate limits. Reply `registered` (+`renew` offer if `renew.1`) then `ice`. Free room: `servers: []`. Room row upserted in D1 (`ctx.waitUntil`). |
| `register` client | same | Host must be online and `SHA256(token) == clientTokenHash` (constant-time) else `host_unavailable_or_unauthorized` (closing, as today). One client per room. If `entitlement` token valid (§5): issue TURN for phone **and** host, send host a second `ice` with servers, phone `registered{access:"remote"}` + `ice` with servers. Otherwise `registered{access:"local"}` (only if `remote.1`), `ice{servers:[]}`; plus non-closing `error entitlement_required` first when the phone listed `remote.1`. Then `peer online` to both. |
| `signal` | RoomDO | Base64 payload 40 B–180 KiB, forwarded verbatim to the counterpart; `peer_unavailable` non-closing when absent. Never parsed or logged. |
| `renew` | RoomDO | Only for peers that negotiated `renew.1`, exact shape. Extends lease to a full lease from now, never a lapsed one; refreshes credentials at a third of TTL; codes `relay_unavailable` / `rate_limited` / `renewal_pending` / `entitlement_required`. Same numbers as `Server/` (lease 1800 s, TURN TTL 3600 s, refresh at TTL/3, retry 30 s). |
| `peer` | RoomDO | On join (both), on client close (host, `online:false`). Host close → client closed `host_disconnected`, room state cleared, credentials revoked. |
| `error` | both | Existing codes unchanged: `invalid_registration`, `unauthorized`, `already_connected`, `host_unavailable_or_unauthorized`, `room_not_approved`, `relay_unavailable`, `invalid_message`, `rate_limit`, `peer_unavailable`, `authentication_timeout`, `registration_pending`. New, only to `remote.1` phones: `entitlement_required`. New close reason `entitlement_revoked`. |
| lease expiry | RoomDO alarm | Host closed `room_lifetime_reached` → client `host_disconnected`, exactly as the fixed lifetime today. |

Limits kept from `Server/`: 256 KiB frames, 200 KiB JSON, 100 messages/s per socket, ≤ 8 ICE servers × 8 URLs, auth timeout 5 s, `Origin` header ⇒ 403 (native only). Backpressure: a socket whose buffered amount exceeds 512 KiB is closed `busy`.

## 3. Rate limits and caps

Cloudflare rate-limiting bindings (per-colo counters, 10 s / 60 s periods) keyed by `cf-connecting-ip`, device or a global key; per-room counters inside the object.

| Where | Key | Limit | On excess |
|---|---|---|---|
| `/signal` upgrade | IP | 30 / min | 429 before upgrade |
| new room (first host registration for a room id) | IP | 10 / min | `room_not_approved` |
| `/v1/entitlements/*` | IP; deviceId | 20 / min; 6 / min (sandbox 3 / min) | 429 |
| `/v1/appstore/notifications` | IP | 120 / min | 429 (Apple retries) |
| TURN issuance | global | 600 / min across the service (account brake) | `relay_unavailable` / `rate_limited` on renew |
| TURN issuance | per room, in object | 6 / min | same |
| messages | per socket, in object | 100 / s | `rate_limit` (closing) |
| sockets | per room | 1 host + 1 client; a third upgrade for the same role is refused | `already_connected` |
| devices | per subscription | 3 | verify → `device_limit` |

Counters in the object are in memory and reset on wake from hibernation; hibernation only happens on an idle room, so the reset is harmless.

## 4. Enrollment (replaces `approve-room`)

Security model unchanged: the service authenticates **routing**, never screen access. The Mac proves it owns a room (`SHA256(hostToken) == room`) and publishes the phone's token hash; the phone proves it knows the client token from the QR code; the E2E AES-GCM envelope and the Mac-side approval happen in the apps. Manual operator approval added nothing to that; it existed to keep an unknown public from consuming TURN, which the entitlement gate now does. So: a self-authenticating host is admitted immediately and its room row is created in D1 (`rooms`: id, first/last seen, status). Operator controls: `POST /v1/admin/rooms/{room}/block|unblock` (admin bearer) sets `status` in D1 and tells the object, which closes both peers `room_not_approved` and revokes credentials; `POST /v1/rooms/forget {room, token}` (the Mac's "Remove this Mac and delete server data") wipes the object's storage and D1 rows when `SHA256(token) == room`.

## 5. Entitlement gate (server half of B2)

Contract: `ENTITLEMENT-CONTRACT.md`. Verification (`src/apple/jws.ts`, `src/apple/x509.ts`) is a self-contained port of the checks Apple's `app-store-server-library` performs (`jws_verification.ts`, read 29 Sep 2026): compact JWS, `alg=ES256`, `x5c` of exactly three certificates, leaf OID `1.2.840.113635.100.6.11.1`, intermediate OID `1.2.840.113635.100.6.2.1`, root pinned by DER equality, each certificate's signature verified with the issuer's key (ECDSA P-256/P-384, DER signature → raw for WebCrypto), validity checked at `signedDate` with 60 s skew (Apple's offline mode; OCSP is not performed — see §11), then `bundleId`, `environment`, `appAppleId` (production), product, type, revocation, expiry. Apple's Node library is not used because it depends on Node-only modules; the port is covered by tests with a locally generated three-certificate chain (never committed keys).

Storage (`D1`): `entitlements` keyed by `HMAC(originalTransactionId)` (privacy policy: "stored hashed"), with product, environment, `expires_at`, `grace_until`, `status` (`active|grace|expired|revoked`), timestamps; `entitlement_devices` (hash, deviceId, first/last seen, last room fingerprint); `notifications` (uuid, type, subtype, received_at) for dedupe; `audit` (event, room fingerprint, hash, at) with no payloads.

Token: `fe1.<payload>.<sig>`, HMAC-SHA256 with `ENTITLEMENT_TOKEN_KEY`; payload `{v:1, d: deviceId, s: entitlementHash, x: expUnixSec, n: "P"|"S"}`; TTL `min(24 h, access end)`. The object verifies the signature (constant-time), expiry, then reads `entitlements.status/expires_at/grace_until` from D1 (one query); D1 unavailable ⇒ trust the unexpired token and log it (fail-open bounded by the 24 h TTL). Revocation reaches live rooms by push: notification handler → `entitlement_devices.last_room` → `RoomDO.revokeEntitlement()`.

Sandbox (D5): accepted in production, `environment: "Sandbox"` stored and returned, tighter per-device limit, separate count in `/ready`. Sandbox and production TURN keys are separate per deployment (§8), so App Review / TestFlight relay minutes on the production service still bill to the production key — acceptable and visible per credential in Cloudflare analytics.

## 6. App Store Server Notifications V2

`POST /v1/appstore/notifications`: verify `signedPayload` with the same chain rules; require `data.bundleId` = ours (and `appAppleId` in production when configured); dedupe by `notificationUUID`; verify the embedded `signedTransactionInfo` / `signedRenewalInfo`; update D1; respond 200 (Apple retries on 40x/50x at 1, 12, 24, 48, 72 h — production only). Unverifiable ⇒ 401. Mapping:

| Type (subtype) | Action |
|---|---|
| `SUBSCRIBED`, `DID_RENEW`, `OFFER_REDEEMED`, `DID_CHANGE_RENEWAL_PREF` | upsert expiry/product, `status=active` |
| `DID_FAIL_TO_RENEW` (`GRACE_PERIOD`) | `status=grace`, `grace_until` = renewal info `gracePeriodExpiresDate` |
| `DID_FAIL_TO_RENEW` (none), `EXPIRED`, `GRACE_PERIOD_EXPIRED` | `status=expired`; no push (natural expiry: live sessions end when credentials do) |
| `REFUND`, `REVOKE` | `status=revoked`, `revoked_at`; push revoke to the device's last room |
| `REFUND_REVERSED` | `status=active` |
| `TEST`, `CONSUMPTION_REQUEST`, everything else | record only |

`POST /v1/admin/appstore/test-notification` asks Apple for a test notification through the App Store Server API (`src/apple/server-api.ts`: ES256 JWT, `aud appstoreconnect-v1`, `bid`, ≤ 60 min) when the In-App Purchase key is configured; the same client re-checks entitlements that are within 48 h of expiry and have had no notification, once a day (cron). Both are optional: without the key the service still works from verify + notifications.

## 7. TURN

Cloudflare Realtime TURN, `POST https://rtc.live.cloudflare.com/v1/turn/keys/{keyId}/credentials/generate-ice-servers` `{ttl}` → 201 `iceServers`; revoke `POST .../credentials/{username}/revoke` → 204 (docs read 29 Sep 2026, same contract as `Server/src/turn.ts`). Issued only inside the room object, only for an entitled room, one credential per peer, 3 s timeout, response ≤ 64 KiB and validated (≤ 8 servers/8 URLs, must contain a `turn:`/`turns:` entry). TTL 3600 s; refresh at a third of TTL through `renew`; superseded sets are not revoked early (an allocation stays bound to its username, `SESSION-LENGTH-FIX.md` §3.2), at most 8 live sets per peer, everything revoked on that peer's disconnect, on host disconnect, on block/forget/entitlement revoke, and the host's set when the phone leaves (no session can use it). Usernames are kept in the object's SQLite for revocation and never logged. Key ID and token are Worker secrets, different per environment. `POCKETDESK_TEST_FORCE_RELAY` (`policy:"relay"`) exists as `TEST_FORCE_RELAY=1` for staging acceptance only; the config refuses it in production.

## 8. Environments and secrets

`wrangler.jsonc` defines `staging` and `production` (Workers `farside-backend-staging` / `farside-backend-production`; the root config is dev-only, never deployed). Bindings are repeated per environment (non-inheritable): `ROOM` (Durable Object), `DB` (D1, separate databases), rate limiters, `vars`. Custom domains (`signal-staging.<domain>`, `signal.<domain>`) go on the `routes` once the domain exists.

| Secret | Set with | Notes |
|---|---|---|
| `CLOUDFLARE_TURN_KEY_ID` | `bunx wrangler secret put CLOUDFLARE_TURN_KEY_ID --env staging` (and `--env production`) | 32 chars; one TURN key per environment |
| `CLOUDFLARE_TURN_KEY_API_TOKEN` | same | 64 chars, shown once by the dashboard |
| `ENTITLEMENT_TOKEN_KEY` | same; generate with `openssl rand -hex 32` | HMAC key for entitlement tokens |
| `ENTITLEMENT_HASH_KEY` | same | HMAC key for hashing `originalTransactionId` |
| `ADMIN_TOKEN` | same | bearer for `/ready` and `/v1/admin/*`, compared constant-time |
| `APPLE_ROOT_CERTS` | same | comma-separated base64 DER of Apple Root CA - G3 (and optionally G2), obtained by the owner with `bun scripts/apple-roots.ts` from https://www.apple.com/certificateauthority/ |
| `APPLE_IAP_ISSUER_ID`, `APPLE_IAP_KEY_ID`, `APPLE_IAP_PRIVATE_KEY` | same (optional) | In-App Purchase key from App Store Connect, PKCS#8 PEM; enables test notifications and daily re-checks |

Vars (non-secret, per env): `ENVIRONMENT_NAME`, `APP_BUNDLE_ID=com.roshan.PocketDesk.Remote`, `APP_APPLE_ID` (empty until the record exists), `ALLOWED_PRODUCT_IDS`, `ACCEPT_SANDBOX`, `ALLOW_XCODE_TRANSACTIONS` (dev only), `STUN_URLS`, `TURN_CREDENTIAL_TTL_SECONDS`, `ROOM_LEASE_SECONDS`, `MAX_DEVICES_PER_ENTITLEMENT`, `TEST_FORCE_RELAY`. Local development reads the same names from `.dev.vars` (`.dev.vars.example` is the template; the real file is git-ignored).

Secrets are read at call time from `env`, never printed; `wrangler secret put` deploys immediately, so set secrets before the first `wrangler deploy --env`.

## 9. Logging and retention (consistent with `Docs/launch/PRIVACY-POLICY.md`)

Structured JSON to Workers Logs only: `event`, `env`, room fingerprint (first 8 hex of the room id), role, error code, durations, counters. Never: signal payloads, tokens, JWS bodies, credentials, usernames, full device IDs, full room IDs. `/health` and `/ready` never contain room IDs or credentials. IP addresses are used for rate-limit keys in memory and are not written to D1 or logs. Workers Logs keep records for the platform default (a few days; check the dashboard and set `head_sampling_rate` lower if volume grows). D1 retention, enforced by the daily cron: `notifications` 90 days, `audit` 30 days, `entitlements` 90 days after access end, `entitlement_devices` with their entitlement, `rooms` 365 days after last seen (or immediately on `forget`). The object deletes its storage on `forget` and when idle for 30 days.

## 10. Cost model (planning, not a quote; prices from Cloudflare pages read 28–29 Sep 2026)

- **Workers Paid, US$5 / month** for the account is recommended for production (higher daily limits, D1 and DO included allowances). Staging can share the account. Staging alone would fit the Free plan (SQLite-backed objects, 100k requests/day) but rate-limit and DO WebSocket message accounting make the Paid floor the safe choice from 16 Oct.
- Signaling: one Worker request + one object request per connection, then ~1 object request per 20 WebSocket messages; a session exchanges a few dozen messages. 5,000 sessions/day ≈ 15k requests/day: inside the Paid allowance (10M Worker + 1M object requests / month). Object duration is only billed while awake (hibernation is free); rooms are idle almost all the time.
- D1: one write per verify/notification, one read per entitled registration; thousands per day, far inside 25 B reads / 50 M writes per month.
- TURN egress: US$0.05 / GB after 1,000 GB / month, the only volume cost; ≈ US$0.20 per relayed hour at 8 Mb/s, ≈ US$1.19 per user per month in the planning model (`Docs/launch/SUBSCRIPTION-SETUP.md` §8). Enforced only for entitled rooms, so free users cost nothing on relay.

## 11. Threat model (what the service defends, what it cannot)

| Threat | Mitigation |
|---|---|
| Unpaid relay use | TURN issued only in rooms whose phone presented a valid entitlement token; token bound to device and subscription; D1 status re-read; revoke pushes; account-wide issuance brake; per-credential analytics |
| Replayed / shared JWS | Device cap per subscription; token bound to the device that verified; sandbox flagged and limited |
| Forged Apple data | Full chain to a pinned Apple root, OIDs, ES256, bundle/product/environment checks; OCSP not performed (Apple's offline mode) — mitigations: 24 h token TTL, notifications, daily re-check when the IAP key is set, root pins updated by redeploy |
| Room squatting / eviction | A room is its host token hash; duplicates are refused, never evicted; the phone needs the QR secret; E2E envelope stays in the apps |
| Signaling service reads content | Payloads are AES-GCM sealed by the apps; the service forwards base64 and validates only length and alphabet |
| Abuse of the HTTP APIs | Size limits (32 KiB bodies, 16 KiB JWS), per-IP and per-device limits, admin bearer compared constant-time, no CORS, no cookies |
| Secret exposure | Secrets only in Worker secrets, never in vars/logs/responses; separate keys per environment; TURN credentials only in the two WebSocket messages |
| Worker/isolate eviction | Socket drops, apps reconnect within their existing budget; room state lives in the object and D1 |
| D1 outage | Verify → 503 (phones keep unexpired tokens); registration with a token → fail-open for the token's remaining life, logged |
| Out of scope | Someone holding an unlocked paired phone; malware on the Mac; DTLS/SRTP (WebRTC); the free tier connecting peer-to-peer across the internet when both peers have public addresses (D1 option A's client-side part is the apps' job) |

## 12. Files, tests, tooling

`src/index.ts` (router, exports `RoomDO`), `src/gateway.ts` (first-frame peek and pipe), `src/room.ts` (object), `src/protocol.ts`, `src/turn.ts`, `src/ratelimit.ts`, `src/entitlement/*` (token, store, verify, notifications), `src/apple/*` (x509, jws, server-api), `src/admin.ts`, `src/log.ts`, `src/util.ts`; `migrations/0001_init.sql`; `test/*` with `@cloudflare/vitest-plugin` (tests run inside workerd: real WebSockets through `SELF`, real object storage, D1 with migrations applied in setup, TURN and Apple mocked by injected `fetch`, a generated three-certificate test chain); `scripts/load-test.ts` (N concurrent rooms against `wrangler dev`); `scripts/apple-roots.ts` (owner fetches and prints the root pins). Commands: `bun install`, `bun run test`, `bun run typecheck`, `bun run dev`, `bun run check` (dry-run deploy for staging).

## 13. Deploy (not performed here)

1. `bunx wrangler login`; `bunx wrangler d1 create farside-entitlements-staging` (and `-production`), paste the ids into `wrangler.jsonc`.
2. Set the secrets in §8 for `--env staging`.
3. `bunx wrangler d1 migrations apply farside-entitlements-staging --env staging --remote`.
4. `bunx wrangler deploy --env staging`; `curl https://<staging>/health`; `bun scripts/load-test.ts --url wss://<staging>/signal --rooms 50`.
5. Point a staging Mac at `wss://<staging>/signal`; pair; verify local-only `ice{servers:[]}`; verify a sandbox purchase enables relay (`/ready` counters); run the forced-relay check with `TEST_FORCE_RELAY=1` on staging only.
6. Repeat for `--env production` with production keys before 23 Oct; enter the notification URLs in App Store Connect; the 72 h soak (checklist 5.10).
