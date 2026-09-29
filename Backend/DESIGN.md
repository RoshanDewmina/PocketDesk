# Farside backend on Cloudflare — design

29 September 2026. Engineering design for launch blocker B1 (production signaling and relay) and the server half of B2 (entitlement gate), subordinate to `PRODUCT.md` (D28, D5). The wire protocol is `Docs/REMOTE-PROTOCOL.md`; the phone-facing entitlement interface is `ENTITLEMENT-CONTRACT.md`. The Bun service in `Server/` stays as the local/dev reference; nothing here changes it or the apps. Current apps work against this service by changing only the service URL (§14 lists what that means for them).

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

- **Worker** (`src/index.ts`, `src/gateway.ts`): routing, per-address rate limits, input size limits, HTTP APIs, admin, cron. Stateless.
- **RoomDO** (`src/room.ts`): the signaling room, keyed `idFromName(room)` where `room = SHA256(hostToken)` exactly as today. Holds both peers' WebSockets with the Hibernation API (`ctx.acceptWebSocket`; per-socket attachments carry role, authentication, entitlement and credential timing so nothing is lost across hibernation), the lease, issued credentials and the entitled state in its own SQLite storage, one alarm for the lease, auth deadlines, entitlement re-checks, revocation retries and the optional keepalive.
- **D1** (`migrations/`): entitlements, device links, notification dedupe, room registry, audit. On the signaling path it is read once when a phone presents a token and once every five minutes for a live entitled room.
- **No Bun, no tunnel, no operator CLI.** Room approval is automatic (§4).

Why the Worker reads the first frame: the apps connect to a fixed `/signal` with no query, header or subprotocol, and send the room only inside the first `register` message (`RemoteShared/SignalingClient.swift`; `PairInvitation.validServer` rejects query strings). A per-room object therefore cannot be chosen at upgrade time. The Worker accepts the socket, waits at most 5 s for one text frame ≤ 200 KiB that parses as `register` with a 64-hex `room`, opens a WebSocket to `ROOM.idFromName(room)` with that frame forwarded, then pipes frames both ways with a per-direction byte budget; frames that arrive while the room socket is being opened are queued (at most 32) and forwarded in order. The Worker is not billed for wall time; if its isolate is evicted the socket drops and the apps' existing bounded reconnect re-registers (the room object is unaffected). Alternatives rejected: one global object (bottleneck, single region), sharded gateway objects (outbound sockets defeat hibernation and double object duration cost), a protocol change (breaks current apps).

## 2. Protocol mapping (REMOTE-PROTOCOL v1, byte-compatible for old apps)

| Message | Where handled | Behaviour |
|---|---|---|
| `register` host | Worker validates shape → RoomDO | `SHA256(token) == room` (constant-time) before anything else, `clientTokenHash` hex, room not blocked (`room_not_approved`), one host per room (`already_connected`, no eviction). Reply `registered` (+`renew` offer if `renew.1`, +`access` if `remote.1`) then `ice{servers:[]}`. Room row upserted in D1 (`ctx.waitUntil`). |
| `register` client | same | Host online and `SHA256(token) == clientTokenHash` (constant-time) else `host_unavailable_or_unauthorized` (closing, as today). One client per room. With a valid entitlement (§5): TURN issued for phone **and** Mac, Mac gets a second `ice` with servers, phone `registered{access:"remote"}` + `ice` with servers. Otherwise `registered{access:"local"}` (only if `remote.1`) and `ice{servers:[]}`, preceded by a non-closing `error entitlement_required` when the phone listed `remote.1`. The Mac must still be the same socket and pairing after the awaits, or the phone gets `host_unavailable_or_unauthorized`. Then `peer online` to both. |
| `signal` | RoomDO | Base64 payload 40 B–180 KiB, forwarded verbatim to the counterpart; `peer_unavailable` non-closing when absent. Never parsed or logged. |
| `renew` | RoomDO | Only for peers that negotiated `renew.1`, exact shape. Extends lease to a full lease from now, never a lapsed one; refreshes credentials at a third of TTL; codes `relay_unavailable` / `rate_limited` / `renewal_pending` / `entitlement_required`. Same numbers as `Server/` (lease 1800 s, TURN TTL 3600 s, refresh at TTL/3, retry 30 s). |
| `peer` | RoomDO | On join (both), on client close (host, `online:false`). Host close → client closed `host_disconnected`, room state cleared, credentials revoked. When an entitled phone leaves, the Mac's credential is revoked and it receives `ice{servers:[]}` so nothing stale survives. |
| `error` | both | Existing codes unchanged: `invalid_registration`, `unauthorized`, `already_connected`, `host_unavailable_or_unauthorized`, `room_not_approved`, `relay_unavailable`, `invalid_message`, `rate_limit`, `peer_unavailable`, `authentication_timeout`, `registration_pending`. New, only to `remote.1` phones: `entitlement_required`. Transient service problems (room object unreachable, room-creation limit, byte budget) close **without** an error frame (1013 `busy` / `rate_limited`) because the apps retry a bare close but stop on an unknown error code. New close reasons: `entitlement_revoked`, `room_forgotten`. |
| lease expiry | RoomDO alarm | Host closed `room_lifetime_reached` → client `host_disconnected`, exactly as the fixed lifetime today; done explicitly, not by waiting for the close handshake. |
| keepalive (optional) | RoomDO alarm | With `KEEPALIVE_SECONDS` > 0 each authenticated peer's last `ice` message is re-sent unchanged; the coordinator only stores its contents. Off by default until the staging idle test (§14) says whether the edge closes quiet sockets. |

Limits kept from `Server/`: 256 KiB frames, 200 KiB JSON, 100 messages/s per socket, ≤ 8 ICE servers × 8 URLs, auth timeout 5 s, `Origin` header ⇒ 403 (native only). Bun's 512 KiB backpressure close has no equivalent API in workerd (no `bufferedAmount`); instead every socket has a 2 MiB/s outbound budget in the object and in each gateway direction, closing 1013 `busy` when exceeded.

## 3. Rate limits and caps

Cloudflare rate-limiting bindings (counters are **per Cloudflare location**, so a global figure is a per-colo figure) keyed by `cf-connecting-ip` (IPv6 by its /64), by device, by subscription or by a fixed key; per-room and per-socket counters live inside the object (in memory; they reset only when an idle room wakes).

| Where | Key | Limit | On excess |
|---|---|---|---|
| `/signal` upgrade | address | 30 / min | HTTP 429 before upgrade |
| first host registration of a new room | address | 10 / min | bare close 1013 `rate_limited` (app retries) |
| `/v1/entitlements/*`, `/v1/rooms/forget` | address; deviceId | 20 / min; 6 / min (sandbox devices 3 / min) | 429 |
| `/v1/appstore/notifications` | address | 120 / min | 429 (Apple retries) |
| TURN issuance | fixed key; subscription | 600 / min per colo; 20 / min per subscription | `relay_unavailable` at registration, `rate_limited` on renew |
| TURN issuance | per room, in object | 6 / min | same |
| messages | per socket, in object | 100 / s | `rate_limit` (closing) |
| outbound bytes | per socket, object and gateway | 2 MiB / s | bare close 1013 `busy` |
| sockets | per room | 1 host + 1 client; a third socket for a taken role (authenticated or mid-registration) is refused | `already_connected` |
| devices | per subscription | 3 (sandbox: 1); a slot unseen for 30 days can be reclaimed | verify → `device_limit` |
| live rooms | per device | 1; a new registration ends the previous room's entitlement | previous room closes `entitlement_revoked` |

## 4. Enrollment (replaces `approve-room`)

Security model unchanged: the service authenticates **routing**, never screen access. The Mac proves it owns a room (`SHA256(hostToken) == room`) and publishes the phone's token hash; the phone proves it knows the client token from the QR code; the E2E AES-GCM envelope and the Mac-side approval happen in the apps. Manual operator approval added nothing to that; it existed to keep an unknown public from consuming TURN, which the entitlement gate now does. So: a self-authenticating host is admitted immediately and its room row is created in D1 (`rooms`: id, first/last seen, status). Operator controls: `POST /v1/admin/rooms/{room}/block|unblock|status` (admin bearer) sets `status` in D1 and tells the object, which closes both peers `room_not_approved` and revokes credentials; a block recorded before the object ever existed is honoured on its first registration. `POST /v1/rooms/forget {room, token}` (the Mac's "Remove this Mac and delete server data") wipes the object's storage and D1 rows when `SHA256(token) == room`; a blocked room answers 403 and stays blocked.

## 5. Entitlement gate (server half of B2)

Contract: `ENTITLEMENT-CONTRACT.md`. Verification (`src/apple/jws.ts`, `src/apple/x509.ts`) is a self-contained port of the checks Apple's `app-store-server-library` performs (`jws_verification.ts`, read 29 Sep 2026): compact JWS, `alg=ES256`, `x5c` of exactly three certificates, leaf OID `1.2.840.113635.100.6.11.1`, intermediate OID `1.2.840.113635.100.6.2.1`, root pinned by DER equality, each certificate's signature verified with the issuer's key (ECDSA P-256/P-384 or RSA, DER signature → raw for WebCrypto, inner and outer algorithm identifiers must agree), validity checked at `signedDate` with 60 s skew (Apple's offline mode; OCSP is not performed — see §11), then `bundleId`, `environment`, `appAppleId` (production), product, type, revocation, expiry. Apple's Node library is not used because it depends on Node-only modules; the port is covered by tests with a locally generated three-certificate chain (never committed keys).

Storage (`D1`): `entitlements` keyed by `HMAC(originalTransactionId)` (privacy policy: "stored hashed"), with product, environment, `expires_at` (monotonic: a stale JWS never moves access backwards), `grace_until`, `revoked_at`, `status` (`active|grace|expired|revoked`), timestamps; `entitlement_devices` (hash, deviceId, first/last seen, `last_room` — the full room id, which is what the revoke push needs to address the object); `notifications` (uuid, type, subtype, received_at) for dedupe; `audit` (event, room fingerprint, hash, at) with no payloads. The device cap is one INSERT…SELECT, so parallel calls cannot exceed it.

Token: `fe1.<payload>.<sig>`, HMAC-SHA256 with `ENTITLEMENT_TOKEN_KEY`; payload `{v:1, d: deviceId, s: entitlementHash, x: expUnixSec, n: "P"|"S"|"X", e: deployment}`; TTL `min(24 h, access end)`; a token minted by staging is refused by production even if a key were reused. A token proves nothing alone: at registration the object requires the (subscription, device) link to still exist and the subscription to have access (one D1 query, 3 s bound); **storage trouble at registration means no relay** (a local-only session for the duration of an outage, bounded by the token's 24 h life), while an established session keeps its credentials if a renewal-time lookup fails. `forget` therefore invalidates a token immediately. A device is live in one room at a time (§3). A live entitled room re-reads its subscription every five minutes and terminates on revocation; refunds also push to the device's `last_room` immediately.

Sandbox (D5): accepted in production, `environment: "Sandbox"` stored and returned, one device per sandbox purchase, tighter per-device limit, separate count in `/ready`. Sandbox and production TURN keys are separate per deployment (§8), so App Review / TestFlight relay minutes on the production service bill to the production key — acceptable and visible per credential in Cloudflare analytics. Unsigned `Xcode`/`LocalTesting` transactions are accepted only when `ENVIRONMENT_NAME` is `dev` or `test`.

## 6. App Store Server Notifications V2

`POST /v1/appstore/notifications`: body ≤ 96 KiB, outer `signedPayload` ≤ 64 KiB (it embeds two chained JWS of ≤ 16 KiB each), verified with the same chain rules; require `data.bundleId` = ours (and `appAppleId` in production when configured); dedupe by `notificationUUID` — checked first, **recorded only after the change applied**, so a failed apply is retried by Apple instead of being dropped; verify the embedded `signedTransactionInfo` / `signedRenewalInfo`; update D1; respond 200 (Apple retries on 40x/50x at 1, 12, 24, 48, 72 h — production only). Unverifiable ⇒ 401. A refund is undone only by `REFUND_REVERSED` or by a purchase made after it; a refund whose period ended before the current paid period leaves access alone (recorded, audited). Mapping:

| Type (subtype) | Action |
|---|---|
| `SUBSCRIBED`, `DID_RENEW`, `OFFER_REDEEMED`, `REFUND_REVERSED`, `RENEWAL_EXTENDED` | payment happened: upsert expiry/product, `status=active`, grace cleared |
| `DID_CHANGE_RENEWAL_PREF`, `DID_CHANGE_RENEWAL_STATUS`, `PRICE_INCREASE` | no payment: refresh product/expiry, keep status and grace |
| `DID_FAIL_TO_RENEW` (`GRACE_PERIOD`) | `status=grace`, `grace_until` = renewal info `gracePeriodExpiresDate` |
| `DID_FAIL_TO_RENEW` (none), `EXPIRED`, `GRACE_PERIOD_EXPIRED` | `status=expired`; no push (natural expiry: live sessions end when credentials do) |
| `REFUND`, `REVOKE` | `status=revoked`, `revoked_at`; push revoke to the device's last room |
| `TEST`, `CONSUMPTION_REQUEST`, everything else | record only |

`POST /v1/admin/appstore/test-notification` asks Apple for a test notification through the App Store Server API (`src/apple/server-api.ts`: ES256 JWT, `aud appstoreconnect-v1`, `bid`, ≤ 60 min) when the In-App Purchase key is configured, and `?token=` reads its delivery status. Optional: without the key the service still works from verify + notifications. A periodic re-check against Apple was considered and left out: it needs a raw transaction id, which conflicts with storing only the HMAC; the 24 h token TTL, verify-on-foreground and notifications bound the exposure instead.

## 7. TURN

Cloudflare Realtime TURN, `POST https://rtc.live.cloudflare.com/v1/turn/keys/{keyId}/credentials/generate-ice-servers` `{ttl}` → 201 `iceServers`; revoke `POST .../credentials/{username}/revoke` → 204 (docs read 29 Sep 2026, same contract as `Server/src/turn.ts`). Issued only inside the room object, only for an entitled room, one credential per peer (if one of the pair fails the other is revoked at once), 3 s timeout, response ≤ 64 KiB and validated (≤ 8 servers/8 URLs, must contain a `turn:`/`turns:` entry). TTL 3600 s; refresh at a third of TTL through `renew`; superseded sets are not revoked early (an allocation stays bound to its username, `SESSION-LENGTH-FIX.md` §3.2), at most 8 live sets per peer, everything revoked on that peer's disconnect, on host disconnect, on block/forget/entitlement revoke, and the host's set when the phone leaves (no session can use it). Revocations are attempted independently per username. Cloudflare's revoke endpoint is eventually consistent right after `generate-ice-servers`: live testing on the Bun relay (29 Sep 2026) saw a first attempt answer 404 `{"error":"cannot find specified username"}` and a retry moments later succeed, so a 404 is **not** taken as done while the credential is younger than 30 s; it is retried like any failure, with exponential backoff and jitter (2 s doubling to 60 s, ±25 %) from the alarm, and each in-flight attempt pushes its own next-attempt time out so the alarm never starts a second round for the same username. A 404 for a credential older than that window, or a 204 at any time, settles it. Retries stop at the credential's own expiry (the TTL backstop). Usernames are kept in the object's SQLite for that purpose and never logged. Key ID and token are Worker secrets, different per environment. `TEST_FORCE_RELAY=1` (`policy:"relay"`) exists for staging acceptance only; the config refuses it in production.

## 8. Environments and secrets

`wrangler.jsonc` defines `staging` and `production` (Workers `farside-backend-staging` / `farside-backend-production`, `workers_dev` and preview URLs off; the root config is dev-only, never deployed). Bindings are repeated per environment (non-inheritable): `ROOM` (Durable Object), `DB` (D1, separate databases), eight rate limiters, `vars`. Custom domains (`signal-staging.<domain>`, `signal.<domain>`) go on the `routes` once the domain exists.

| Secret | Set with | Notes |
|---|---|---|
| `CLOUDFLARE_TURN_KEY_ID` | `bunx wrangler secret put CLOUDFLARE_TURN_KEY_ID --env staging` (and `--env production`) | 32 chars; one TURN key per environment |
| `CLOUDFLARE_TURN_KEY_API_TOKEN` | same | 64 chars, shown once by the dashboard |
| `ENTITLEMENT_TOKEN_KEY` | same; generate with `openssl rand -hex 32` | HMAC key for entitlement tokens |
| `ENTITLEMENT_HASH_KEY` | same | HMAC key for hashing `originalTransactionId` |
| `ADMIN_TOKEN` | same (≥ 32 chars) | bearer for `/ready` and `/v1/admin/*`, compared constant-time |
| `APPLE_ROOT_CERTS` | same | comma-separated base64 DER of Apple Root CA - G3 (and optionally G2), obtained by the owner with `bun scripts/apple-roots.ts` from https://www.apple.com/certificateauthority/ |
| `APPLE_IAP_ISSUER_ID`, `APPLE_IAP_KEY_ID`, `APPLE_IAP_PRIVATE_KEY` | same (optional) | In-App Purchase key from App Store Connect, PKCS#8 PEM; enables the test-notification admin route |

Vars (non-secret, per env): `ENVIRONMENT_NAME`, `APP_BUNDLE_ID=com.roshan.PocketDesk.Remote`, `APP_APPLE_ID` (empty until the record exists; production `/ready` stays `not_ready` without it), `ALLOWED_PRODUCT_IDS`, `ACCEPT_SANDBOX`, `ALLOW_XCODE_TRANSACTIONS` (dev/test only), `STUN_URLS`, `TURN_CREDENTIAL_TTL_SECONDS`, `ROOM_LEASE_SECONDS`, `MAX_DEVICES_PER_ENTITLEMENT`, `TEST_FORCE_RELAY`, `ALLOW_UNENTITLED_RELAY` (dev/staging migration switch: peers without `remote.1` still get relay, so the owner can exercise relay on staging before the StoreKit app lands; refused in production), `KEEPALIVE_SECONDS` (0 off, else 15–600). Local development reads the same names from `.dev.vars` (`.dev.vars.example` is the template; the real file is git-ignored).

Secrets are read at call time from `env`, never printed; `wrangler secret put` deploys immediately, so set secrets before the first `wrangler deploy --env`.

## 9. Logging and retention (consistent with `Docs/launch/PRIVACY-POLICY.md`)

Structured JSON to Workers Logs only, with invocation logs and traces switched off (invocation logs would record client addresses; trace spans would carry outbound URLs that include TURN usernames): `event`, `env`, room fingerprint (first 8 hex of the room id), role, error code, durations, counters. Never: signal payloads, tokens, JWS bodies, credentials, usernames, full device IDs, full room IDs. `/health` and `/ready` never contain room IDs or credentials. Client addresses are used for rate-limit keys in memory and are not written to D1 or logs. Workers Logs keep records for the platform default (a few days; check the dashboard and set `head_sampling_rate` lower if volume grows). D1 retention, enforced by the daily cron: `notifications` 90 days, `audit` 30 days, `entitlements` 90 days after access end, `entitlement_devices` with their entitlement, `rooms` 365 days after last seen (or immediately on `forget`; blocked rooms are kept). The object deletes its storage on `forget` and when idle for 30 days.

## 10. Cost model (planning, not a quote; prices from Cloudflare pages read 28–29 Sep 2026)

- **Workers Paid, US$5 / month** for the account is recommended for production (higher daily limits, D1 and DO included allowances). Staging can share the account. Staging alone would fit the Free plan (SQLite-backed objects, 100k requests/day) but rate-limit and DO WebSocket message accounting make the Paid floor the safe choice from 16 Oct.
- Signaling: one Worker request + one object request per connection, then ~1 object request per 20 WebSocket messages; a session exchanges a few dozen messages. 5,000 sessions/day ≈ 15k requests/day: inside the Paid allowance (10M Worker + 1M object requests / month). Object duration is only billed while awake (hibernation is free); rooms are idle almost all the time. A live entitled room wakes once per five minutes; with keepalive on, every registered Mac wakes every `KEEPALIVE_SECONDS` (1,000 Macs at 60 s ≈ 43M object requests / month ≈ US$6.5).
- D1: one write per verify/notification, one read per entitled registration and per five minutes of a live entitled room; thousands per day, far inside 25 B reads / 50 M writes per month.
- TURN egress: US$0.05 / GB after 1,000 GB / month, the only volume cost; ≈ US$0.20 per relayed hour at 8 Mb/s, ≈ US$1.19 per user per month in the planning model (`Docs/launch/SUBSCRIPTION-SETUP.md` §8). Enforced only for entitled rooms, so free users cost nothing on relay.

## 11. Threat model (what the service defends, what it cannot)

| Threat | Mitigation |
|---|---|
| Unpaid relay use | TURN issued only in rooms whose phone presented a valid entitlement token; token bound to device, subscription and deployment; (subscription, device) link and access re-read from D1 at registration and every five minutes; one live room per device; ≤ 3 devices per subscription (sandbox 1); per-subscription and per-colo issuance brakes; revoke pushes; per-credential analytics |
| Replayed / shared JWS or token | Device cap enforced atomically; token bound to the device that verified and dies with `forget`; sandbox flagged and limited to one device |
| Forged Apple data | Full chain to a pinned Apple root, OIDs, ES256, algorithm agreement, bundle/product/environment checks; OCSP not performed (Apple's offline mode) — mitigations: 24 h token TTL, verify-on-foreground, notifications, root pins updated by redeploy |
| Notification races | Dedupe recorded after apply; refunds survive late retries of older notices; earlier-period refunds do not touch a newer period |
| Room squatting / eviction | A room is its host token hash, authenticated before presence is revealed; duplicates are refused, never evicted; a phone is admitted only against the Mac socket it authenticated with; kicked or expired sockets are detached before closing so a late close cannot disturb a replacement |
| Signaling service reads content | Payloads are AES-GCM sealed by the apps; the service forwards base64 and validates only length and alphabet |
| Abuse of the HTTP APIs and sockets | Size limits (32/96 KiB bodies, 16/64 KiB JWS), per-address (IPv6 /64), per-device and per-subscription limits, byte budgets, bounded gateway backlog, admin bearer compared constant-time, no CORS, no cookies |
| Secret exposure | Secrets only in Worker secrets, never in vars/logs/responses/traces; separate keys per environment; TURN credentials only in the two WebSocket messages |
| Worker/isolate eviction | Socket drops, apps reconnect within their existing budget; room state lives in the object and D1 |
| D1 outage | Verify → 503 (phones keep unexpired tokens); registration with a token → local-only; established sessions keep their credentials; re-check failures are logged, not fatal |
| Out of scope | Someone holding an unlocked paired phone; malware on the Mac; DTLS/SRTP (WebRTC); the free tier connecting peer-to-peer across the internet when both peers have public addresses (D1 option A's client-side part is the apps' job); a paying user who shares their phone's token with three friends (the device cap is the ceiling) |

## 12. Files, tests, tooling

`src/index.ts` (router, cron, exports `RoomDO`), `src/gateway.ts` (first-frame peek and pipe), `src/room.ts` (object), `src/protocol.ts`, `src/turn.ts`, `src/ratelimit.ts`, `src/config.ts`, `src/entitlement/*` (token, store, verify, notifications), `src/apple/*` (x509, jws, server-api), `src/admin.ts`, `src/log.ts`, `src/util.ts`; `migrations/0001_init.sql`; `test/*` with `@cloudflare/vitest-plugin` (tests run inside workerd: real WebSockets through `SELF`, real object storage including eviction, D1 with migrations applied in setup, TURN mocked by a global-fetch spy, a three-certificate Apple-shaped chain generated per run, fake `Date` plus `runDurableObjectAlarm` for hours-long lease scenarios; storage is isolated per test file); `scripts/load-test.ts` (N concurrent rooms against `wrangler dev` or a deployment); `scripts/apple-roots.ts` (owner fetches and prints the root pins). Commands: `bun install`, `bun run test`, `bun run typecheck`, `bun run dev`, `bun run check` (dry-run deploy for staging).

## 13. Deploy (not performed here)

1. `bunx wrangler login`; `bunx wrangler d1 create farside-entitlements-staging` (and `-production`), paste the ids into `wrangler.jsonc`.
2. Set the secrets in §8 for `--env staging`.
3. `bunx wrangler d1 migrations apply farside-entitlements-staging --env staging --remote`.
4. `bunx wrangler deploy --env staging`; `curl https://<staging>/health`; `bun scripts/load-test.ts --url wss://<staging>/signal --rooms 50`.
5. Point a staging Mac at `wss://<staging>/signal`; pair; verify local-only `ice{servers:[]}`; with `ALLOW_UNENTITLED_RELAY=1` on staging, run the forced-relay check (`TEST_FORCE_RELAY=1`) and the idle test in §14; once the StoreKit build exists, verify a sandbox purchase enables relay (`/ready` counters) and turn `ALLOW_UNENTITLED_RELAY` off again.
6. Repeat for `--env production` with production keys before 23 Oct; enter the notification URLs in App Store Connect; the 72 h soak (checklist 5.10).

## 14. Verification status (29 Sep 2026) and what current apps get

**Verified locally:** `bun run typecheck` clean; `bun run test` → 9 files, 86 tests pass inside workerd (protocol parity ported from `Server/tests`, entitlement gate, hibernation survival, lease/renewal over simulated hours, revocation retry, five-minute re-check, notifications including refund ordering and realistic sizes, admin/forget/block, gateway limits); `wrangler deploy --dry-run` for both environments; `wrangler dev` plus `scripts/load-test.ts` with 100 concurrent rooms (200 sockets, 20 signal round trips each, one spoofed source address per room): 100/100 rooms succeeded, connect p50 234 ms / p95 310 ms, signal round trip p50 44 ms / p95 89 ms, no errors in the dev log — figures for a single local workerd, useful only as a smoke test of the whole path. The same run from one shared address stops at ten rooms by design (address limits). An independent read-only security review and a protocol-parity review of the code were done and their findings folded in.

**Not verified (needs staging on real Cloudflare):** whether the edge closes WebSockets idle between 900 s renewals (the Bun service pinged; the apps never do) — run a 10-minute idle live session and a Mac waking from sleep; if sockets drop, set `KEEPALIVE_SECONDS=50`; any real TURN allocation; Apple's real certificate chain and notification sizes against the pins (the tests use a generated chain of the same shape); the `ratelimits` binding's behaviour at scale; Workers Logs retention.

**Current apps against this service:** identical message shapes, ordering, codes and timings; no STUN or TURN (free tier, D28), so they connect only where host candidates reach — the same network. Relay returns for phones that carry a valid entitlement token (`remote.1`, the StoreKit work) or, on staging only, with `ALLOW_UNENTITLED_RELAY=1`.
