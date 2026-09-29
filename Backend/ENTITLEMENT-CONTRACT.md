# Farside entitlement contract (server ↔ phone)

**Status: v1, frozen 29 September 2026.** This is the interface the StoreKit work in the phone app implements against and the backend in `Backend/` serves. Changes are announced in the commit message and in this file's changelog (bottom). Subordinate to `PRODUCT.md` (D28: internet access requires the paid plan, enforced on the server; D5 in `Docs/launch/SUBSCRIPTION-SETUP.md`: sandbox accepted in production, flagged and rate-limited).

Base URL: `https://<service host>` — the same host as the `wss://<service host>/signal` address baked into the apps. Staging and production are different hosts (`Backend/DESIGN.md` §8). All bodies are JSON, UTF-8, `Content-Type: application/json`. Requests larger than 32 KiB are rejected.

## 1. Identifiers

| Name | Format | Who makes it | Notes |
|---|---|---|---|
| `deviceId` | 64 lowercase hex characters (32 random bytes) | The phone, once per install, stored in the Keychain | Not derived from any Apple identifier, name or vendor ID. Sent only to this service. Never logged in full (first 8 hex only). |
| `signedTransaction` | StoreKit 2 `Transaction.jwsRepresentation` (compact JWS) | Apple, via StoreKit | ≤ 16 KiB. Passed verbatim; never store or log it on the server. |
| `entitlementToken` | Opaque string `fe1.<base64url payload>.<base64url signature>`, ≤ 512 bytes | The server | Short-lived (§3). The phone stores it in the Keychain and presents it in `register`. |

## 2. `POST /v1/entitlements/verify`

Called by the phone (a) after a purchase or restore, (b) on every `Transaction.updates` event, (c) on foreground when the stored token is older than 12 hours or expires within 6 hours, (d) when signaling answers `entitlement_required`.

Request:

```json
{ "signedTransaction": "<jwsRepresentation>", "deviceId": "<64 hex>" }
```

Server checks, in order:

1. Body shape and sizes; `deviceId` format.
2. JWS: `alg` is `ES256`; `x5c` holds exactly three certificates; leaf carries Apple's in-app-purchase signing OID `1.2.840.113635.100.6.11.1`, intermediate carries `1.2.840.113635.100.6.2.1`; the third certificate equals a pinned Apple root (Apple Root CA - G3; G2 accepted as a fallback pin); each certificate is signed by the next and valid at `signedDate`; the JWS signature verifies with the leaf key.
3. `bundleId == com.roshan.PocketDesk.Remote`.
4. `productId ∈ { com.roshan.PocketDesk.remote.monthly, com.roshan.PocketDesk.remote.yearly }` and `type == "Auto-Renewable Subscription"`.
5. `environment`: `Production` always; `Sandbox` when the deployment allows it (production does, flagged, with tighter rate limits); `Xcode` / `LocalTesting` only on a developer's local `wrangler dev` (never staging or production).
6. In production, `appAppleId` must equal the configured app Apple ID once it is configured (it is unknown until the App Store Connect record exists).
7. `revocationDate` absent; `expiresDate` (plus billing-grace allowance already known from notifications) in the future.
8. Device cap: at most 3 distinct `deviceId`s per subscription (per `originalTransactionId`); sandbox purchases get 1. A further device is refused with `device_limit`; unlinking (§5) frees a slot, and a slot whose device has not verified for 30 days is reclaimed automatically.

Responses:

| Status | Body | Meaning |
|---|---|---|
| 200 | `{"entitled": true, "expiresAt": "<ISO 8601 UTC>", "environment": "Production"\|"Sandbox", "productId": "...", "inGracePeriod": false, "entitlementToken": "fe1...", "tokenExpiresAt": "<ISO>"}` | Store the token; present it in `register`. |
| 200 | `{"entitled": false, "reason": "expired"\|"revoked"\|"device_limit", "expiresAt": "<ISO>"?, "environment": "..."}` | Valid Apple data, no access. Show the paywall / expired state. No token. |
| 400 | `{"error": "invalid_request"}` | Malformed body or sizes. Do not retry unchanged. |
| 401 | `{"error": "invalid_transaction", "reason": "signature"\|"wrong_app"\|"wrong_product"\|"environment_not_accepted"\|"not_subscription"}` | The JWS did not pass. Do not retry unchanged; `environment_not_accepted` means an Xcode-signed transaction reached a real server. |
| 429 | `{"error": "rate_limited", "retryAfterSeconds": n}` | Back off. |
| 503 | `{"error": "unavailable"}` | Storage or Apple root configuration problem. Retry with backoff; keep using an unexpired stored token. |

Rules for the phone: the server never revokes a token it issued early except through signaling (§4); treat `tokenExpiresAt` as authoritative and refresh before it passes. Never send the token anywhere but `register` on this service. A phone with no token behaves as free / same-network only.

## 3. Token semantics

- Signed by the server (HMAC-SHA256, key held only server-side). Opaque to the phone; do not parse it.
- Lifetime: `min(24 h, access end)`, where access end is the later of `expiresDate` and the billing-grace end known to the server. Typical: 24 h.
- Bound to the `deviceId` that verified, to the subscription and to the deployment that minted it (a staging token is refused by production). On every `register` the server also requires the device to still be linked to the subscription and the subscription to have access, so `forget` (§5) or a refund stops a token at once, not at its expiry.
- One live room per device: registering with the token in a second room ends the first room's relay (its peers close with `entitlement_revoked`). A phone that reconnects to the same Mac is unaffected.
- Server-side revocation (refund, revoke, expiry notice, block) takes effect on the next `register` or `renew`, immediately for a live room through a push, and within five minutes through the room's own re-check (§4).
- A storage outage on the server means `register` proceeds as local-only for that connection; an already established relayed session keeps its credentials.

## 4. Signaling: additive protocol change (`Docs/REMOTE-PROTOCOL.md`, capability `remote.1`)

Wire messages stay as documented. Additions, all ignored by older apps:

- The phone adds `"remote.1"` to `register.features` and, when it has one, `"entitlement": "<entitlementToken>"`. The Mac adds nothing.
- `registered` to a peer that listed `remote.1` carries `"access": "remote" | "local"`.
- `ice`: for a room whose phone is entitled, both peers receive STUN and short-lived TURN servers. The Mac, which registers before the phone, receives a second `ice` message with servers immediately before `peer` `online: true`. For a free room every `ice` carries `"servers": []`.
- `error` with `"code": "entitlement_required"` is sent to a phone that listed `remote.1` and presented no token, an expired token, a token for another device, or a token whose subscription is no longer active. It is **non-closing**: `registered` (`access: "local"`) and `ice` (`servers: []`) follow and the session proceeds as same-network only. The phone should call `/v1/entitlements/verify` (with its latest transaction) and reconnect if that yields a token.
- `renewed` for a phone whose entitlement lapsed mid-session carries `"code": "entitlement_required"` and no `servers`; the lease is still extended and the session continues until the credentials in use expire (natural expiry). A refund, revoke or operator block ends the room at once: both sockets close with reason `entitlement_revoked` (or `room_not_approved`) and every issued relay credential is revoked.
- When the entitled phone leaves, the Mac receives `ice` with `"servers": []` after `peer` `online:false`, so its next session starts from the free state until a phone with a valid token joins again.
- The service may repeat a peer's most recent `ice` message unchanged as a keepalive; peers treat it exactly like the first.
- Transient service problems close the socket **without** an error frame (close code 1013, reason `busy` or `rate_limited`); the phone's ordinary reconnect handles them.
- Phones that do not list `remote.1` never receive the new codes and fields; they get `servers: []` and connect only where host candidates reach (same network).

## 5. `POST /v1/entitlements/forget`

Privacy path ("Remove this Mac and delete server data", `Docs/launch/PRIVACY-POLICY.md`). Body `{"deviceId": "<64 hex>", "entitlementToken": "fe1..."}`. Unlinks that device from its subscription record (frees a device slot) and invalidates that device's token immediately; a later `verify` from the same device links it again. 204 on success (also when already unlinked), 401 when the token does not match the device, 400/429 as above. The subscription record itself is deleted 90 days after its access end (retention, DESIGN.md §9).

## 6. `POST /v1/appstore/notifications` (Apple → server)

App Store Server Notifications V2. Body `{"signedPayload": "<JWS>"}`. Both the production and the sandbox notification URLs in App Store Connect point at the production service; the payload's `data.environment` distinguishes them. Not called by the phone. Verification and handling: DESIGN.md §6.

## 7. Test hooks

- Staging accepts `Sandbox` and `Production`. `Xcode` transactions are accepted only by `wrangler dev` with `ENVIRONMENT_NAME=dev`.
- A verify request whose transaction was already recorded returns the current state (idempotent) and a fresh token.
- Rate limits (production): 20 verify calls per minute per IP, 6 per minute per device, sandbox devices 3 per minute. Sandbox entitlements are marked in storage and reported with `environment: "Sandbox"`.

## Changelog

- 2026-09-29 v1: initial contract.
- 2026-09-29 v1.1 (same day, before any client implementation): token also bound to the deployment and to a live device link; `forget` invalidates immediately; one live room per device; sandbox purchases get one device; stale device slots reclaimed after 30 days; Mac receives `ice{servers:[]}` when its entitled phone leaves; keepalive `ice` repeats; bare 1013 closes for transient failures. Request and response shapes of §2 are unchanged.
