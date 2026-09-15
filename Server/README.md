# PocketDesk private signaling service

This Bun service authenticates one approved PocketDesk host room, brokers opaque encrypted signaling messages, and issues short-lived TURN credentials. It does not terminate media encryption or carry video/input traffic. The wire messages remain `register`, `registered`, `ice`, `peer`, `signal`, and `error`.

## Local development

Requires Bun. From this directory:

```sh
bun test
bun run start
```

Development defaults to `127.0.0.1:8787` and does not require TURN. That is suitable for local integration only. `NODE_ENV=production` fails at startup unless approved room IDs and one complete relay provider are configured.

## Private production shape

Keep Bun bound to loopback and put a TLS reverse proxy in front of it. The native apps must use `wss://your-private-name.example/signal`. The proxy must:

- present a trusted TLS certificate and support WebSocket upgrades on `/signal`;
- be the only process able to reach the Bun port; do not expose port 8787 publicly;
- reject other public paths, cap connection attempts and request size, and apply an idle timeout compatible with WebSocket pings;
- preserve the WebSocket connection without inspecting or logging message bodies or authorization material.

`Caddyfile.private.example` is a minimal single-host TLS example. `/health` is intentionally absent from its public routes; check `http://127.0.0.1:8787/health` on the server. The app ignores forwarded-IP headers because accepting them without a strict trusted-proxy model would let callers spoof the rate-limit key. For this one-pair private MVP, its in-process upgrade limit therefore sees the reverse proxy as one source; retain a proxy-side per-client connection limit.

The WebSocket handshake is public at the TLS endpoint. Room authentication occurs immediately after upgrade and is bounded by `AUTH_TIMEOUT_MS`. If an additional identity gateway is required, the native clients and proxy need a coordinated credential mechanism; do not place an interactive browser login in front of `/signal` and assume the native apps can pass it.

A phone that registers before its host receives `host_unavailable_or_unauthorized` and that socket closes. Retrying must use a fresh WebSocket after the host has registered. The service test suite locks this contract; the native coordinator owns its retry behavior.

Copy `.env.private.example` to a service-manager-owned environment file outside the repository. Restrict it to the service account. Never place the host token, client token, coturn secret, or Cloudflare API token in source, proxy URLs, command arguments, or logs. `ALLOWED_ROOMS` contains only approved room IDs (the SHA-256 room identifiers), not the underlying host token.

### Approving the Mac's generated room

For first pairing, use `APPROVED_ROOMS_FILE` and `PENDING_ROOMS_FILE` instead of a static `ALLOWED_ROOMS`. Both must be absolute paths outside the repository. Create the approved file before service start and restrict it to the service account:

```sh
install -m 600 /dev/null /absolute/private/path/approved-rooms
```

An unknown host must first prove that its host token hashes to its proposed room. The service then closes it with `room_pending_<12 hex characters>` and records only the room ID, fingerprint, and request time for at most five minutes. Compare that fingerprint with the code shown in the Mac status, then approve that exact request locally:

```sh
bun run approve-room list --approved-file /absolute/private/path/approved-rooms --pending-file /absolute/private/path/pending-rooms.json
bun run approve-room approve --approved-file /absolute/private/path/approved-rooms --pending-file /absolute/private/path/pending-rooms.json --fingerprint 12hexcharacters
```

On the Mac, click **Enable remote access** after approval. It reuses the same saved invitation; clicking **Pair a phone** would create a different room. Remove a temporary approval after the test with the `revoke` action and the same fingerprint. Approval files never contain the host token, client token, media key, or pairing code. Pending requests are bounded to 16 entries and expire from the operator view.

The service audits file-backed approvals every `APPROVAL_AUDIT_INTERVAL_MS` (1000 ms by default and in the standalone example, configurable from 100 to 5000 ms). Revoking a fingerprint removes the room from the approval file; on the next audit the service removes the active room, closes both signaling sockets, and starts revoking each peer's issued TURN credentials. With the standalone value and a responsive event loop, the scheduled signaling-revocation delay is at most one second. There is no hard wall-clock maximum if the process event loop is blocked or the process is unhealthy. The Cloudflare provider attempt is then bounded by `TURN_PROVIDER_TIMEOUT_MS` (three seconds in the example). Provider failure or a forced process exit leaves credential TTL expiry, one hour in the example, as the backstop. Static `ALLOWED_ROOMS` entries are not controlled by the file-revoke command.

Room-file mutations take a private sidecar lock. A malformed lock, or a lock older than 30 seconds whose owner process is dead, fails closed and is never removed automatically. Stop every process using that approval file, inspect the lock's `pid`, `createdAt`, and `nonce`, verify that the owner is gone, and then remove only that exact `<approved-file>.lock` before retrying. This explicit recovery avoids deleting a replacement lock acquired between inspection and cleanup.

## Managed Cloudflare TURN

Set `TURN_PROVIDER=cloudflare`, `CLOUDFLARE_TURN_KEY_ID`, and `CLOUDFLARE_TURN_KEY_API_TOKEN`. Create the TURN key in the Cloudflare dashboard or control-plane API; the long-lived key stays on this server. PocketDesk calls Cloudflare's current `generate-ice-servers` endpoint once for each authenticated peer and passes only the returned short-lived ICE username and credential to that peer.

The request uses the documented `POST /v1/turn/keys/{key_id}/credentials/generate-ice-servers` contract and requires HTTP 201 plus a valid relay entry. Provider rejection, malformed JSON, a response without a TURN URL, or timeout produces `error: relay_unavailable`; the room is not authorized. See Cloudflare's [Generate Credentials](https://developers.cloudflare.com/realtime/turn/generate-credentials/) documentation.

`TURN_CREDENTIAL_TTL_SECONDS` defaults to 3600 and is constrained here to 60–86400 seconds, below Cloudflare's documented 48-hour maximum. `TURN_PROVIDER_TIMEOUT_MS` defaults to 3000 and must be lower than `AUTH_TIMEOUT_MS`. Runtime refresh during a session is not implemented, so `ROOM_LIFETIME_SECONDS` must remain below the credential lifetime for a bounded test. The service attempts Cloudflare's credential revocation endpoint when a signaling peer disconnects; TTL expiry remains the cleanup backstop if revocation is unavailable.

`TURN_CREDENTIAL_ISSUES_PER_MINUTE` is an account-side issuance brake in addition to room authorization, connection limits, and authentication timeouts. It does not meter relayed bytes. Cloudflare TURN analytics and billing controls remain external provider controls; forced-relay physical testing is still required to observe real usage. Shutdown waits up to five seconds for in-flight credential requests and revocations; a credential returned after its socket closes is revoked before clean shutdown when it completes inside that bound. TTL expiry remains the backstop after a provider hang or forced process kill.

## Self-hosted coturn shared-secret mode

Set `TURN_PROVIDER=coturn`, `TURN_URLS`, and `TURN_SECRET`. This is deliberately separate from Cloudflare mode. The service creates the expiring username and HMAC-SHA1 credential expected by coturn's TURN REST shared-secret authentication. The coturn instance must be configured with the same secret, TLS as applicable, its own allocation/bandwidth quotas, and a restricted relay port range. `TURN_SECRET` must contain at least 32 characters and must never be logged.

## Configuration

| Variable | Default | Validation / purpose |
|---|---:|---|
| `NODE_ENV` | — | `production` enables mandatory room and relay checks |
| `BIND` | `127.0.0.1` | Bun listen address; keep loopback behind the proxy |
| `PORT` | `8787` | 1–65535 |
| `ALLOWED_ROOMS` | — | Unique comma-separated 64-character lowercase hex room IDs; required in production |
| `APPROVED_ROOMS_FILE` | — | Private absolute path for live room approvals; alternative to `ALLOWED_ROOMS` |
| `PENDING_ROOMS_FILE` | — | Private absolute path for bounded fingerprint-confirmed first pairing |
| `PENDING_ROOM_TTL_SECONDS` | `300` | 60–900 |
| `APPROVAL_AUDIT_INTERVAL_MS` | `1000` | 100–5000; file-backed active rooms are closed on the next audit after revocation |
| `TURN_PROVIDER` | — | `cloudflare` or `coturn`; required in production |
| `TURN_CREDENTIAL_TTL_SECONDS` | `3600` | 60–86400 |
| `TURN_PROVIDER_TIMEOUT_MS` | `3000` | 250–10000 and lower than auth timeout |
| `CLOUDFLARE_TURN_KEY_ID` | — | 32-character Cloudflare TURN key ID |
| `CLOUDFLARE_TURN_KEY_API_TOKEN` | — | 64-character server-only TURN key bearer token for issuing credentials |
| `TURN_URLS` | — | Comma-separated `turn:` / `turns:` URLs for coturn |
| `TURN_SECRET` | — | Coturn shared secret, at least 32 characters |
| `STUN_URLS` | — | Optional comma-separated `stun:` / `stuns:` URLs |
| `AUTH_TIMEOUT_MS` | `5000` | 1000–30000 |
| `MAX_PEERS` | `256` | 2–10000 open WebSockets |
| `CONNECTION_ATTEMPTS_PER_MINUTE` | `30` | 2–10000 upgrades per observed source |
| `MESSAGES_PER_SECOND` | `100` | 2–1000 messages per connection |
| `TURN_CREDENTIAL_ISSUES_PER_MINUTE` | `12` | 2–120 provider credential calls across the process |
| `ROOM_LIFETIME_SECONDS` | `1800` | 60–86400; closes signaling so native clients tear down media |

The service also caps WebSocket payloads at 256 KiB, accepted JSON text at 200 KiB, encrypted `signal.payload` at 180 KiB, provider responses at 64 KiB, ICE output at 8 servers with 8 URLs each, and backpressure at 512 KiB. Clients that miss authentication, exceed limits, or fail relay provisioning receive an existing `error` message and are closed. `/health` reports only service/protocol status and never provider configuration or secrets.

Passing automated tests and a local health response establish configuration and failure behavior only. Cellular reachability, WSS certificate acceptance, Cloudflare account access, actual TURN allocation, forced-relay route selection, quotas, and relay spend still require a real private deployment and physical-device test.

## Standalone deployment check

`Caddyfile.standalone.example` keeps the service on dedicated loopback ports and exposes only `/signal` to Cloudflare Tunnel. `cloudflared.standalone.yml.example` is the named-tunnel form. For the already-approved temporary experiment, `scripts/run-bounded-standalone.sh` can instead launch a Quick Tunnel for at most one hour and cleans up only its own child processes. It intentionally does not install `cloudflared`, log in, create a tunnel, change DNS, or accept provider terms.

Before a tunnel is started, the runner calls the readiness check. You can run it separately against the private environment file; this makes a real credential request, validates the returned configuration against the native 8-by-8 ICE limit, and revokes the credential when the provider supports revocation:

```sh
bun run readiness --env-file /absolute/private/path/pocketdesk.env
```

After the endpoint is live, add `--wss wss://signal.example.com/signal`. The check temporarily approves a generated room, authenticates a synthetic host and phone through the public WSS route, validates the real ICE messages, closes both peers, and restores the prior approval set. This proves WSS signaling and provider credential issuance. It does not prove that a TURN allocation carries media; that requires the physical phone's **Relay-only test** and route diagnostics to report `Relay`.
