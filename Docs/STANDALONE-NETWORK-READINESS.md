# PocketDesk standalone network readiness

**Checked:** 13 September 2026  
**Scope:** one Mac and one iPhone feasibility test, without Tailscale  
**Verdict:** locally ready to configure; live public WSS and real TURN remain blocked on the explicitly deferred Cloudflare account, TURN-key, and public-activation steps

## Minimum deployment path

The smallest current path is the existing Bun signaling service on loopback, the repository's loopback Caddy filter, a time-bounded Cloudflare Quick Tunnel for public WSS, and a dedicated Cloudflare Realtime TURN key for relayed WebRTC. This keeps `/signal` as the only public HTTP route and keeps media outside the tunnel. The WSS tunnel carries only opaque encrypted negotiation messages; TURN carries media and control only when ICE selects relay.

This path does not require Tailscale. It is a feasibility setup, not the public product architecture. Cloudflare documents Quick Tunnels as free testing/development infrastructure without an SLA, with a 200 in-flight request limit. A later stable endpoint should use a named tunnel and controlled DNS, or a hosted signaling service, after a separate deployment decision. Cloudflare Tunnel supports WebSockets and uses outbound connections from the origin. [Quick Tunnel documentation](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/) · [Tunnel FAQ](https://developers.cloudflare.com/cloudflare-one/faq/cloudflare-tunnels-faq/)

## What is implemented

- Production configuration can use a private, reloadable approved-room file. An unknown Mac must first prove possession of a host token whose SHA-256 digest is its room ID.
- A proven but unapproved Mac is recorded for at most five minutes as a room ID plus a 12-character fingerprint. The Mac displays `room_pending_<fingerprint>`. Local approval requires that exact fingerprint; no host token, phone token, pairing code, or media key is stored in the deployment files.
- Provider credential issuance is capped across the service process. Signaling rooms have a maximum lifetime, which makes the native clients tear down WebRTC when the signaling connection closes.
- Cloudflare credentials are short lived and are revoked on signaling disconnect when the provider accepts revocation. TTL expiry remains the cleanup backstop.
- File-backed approvals are audited every second in the standalone configuration. Revoking an active room removes it immediately from the approval file; the next audit removes the live room, closes both signaling sockets, and begins revoking both peers' issued TURN credentials. With a responsive event loop, the scheduled signaling-revocation delay is at most one second; there is no hard wall-clock maximum if the single-threaded process is blocked or unhealthy. Each Cloudflare revocation attempt is then bounded by the configured three-second provider timeout; the one-hour credential TTL remains the backstop if the provider cannot revoke it.
- Room approvals and pending requests use serialized cross-process mutations, atomic replacement, and bounded lock waits. Malformed locks and stale dead-owner locks fail closed for explicit operator cleanup; the service never unlinks an inspected stale lock and therefore cannot delete a newly acquired replacement. Readiness removes only the room it generated, preserving concurrent approvals and revocations.
- The readiness command makes a real provider request, checks that the response contains authenticated TURN URLs within the native client's limit of 8 ICE servers and 8 URLs per server, and confirms revocation. With `--wss`, it temporarily approves a generated room and authenticates a synthetic host and phone through the public endpoint before removing only that generated room.
- Clean shutdown waits up to five seconds for registrations, provider issuance, and revocation. Credentials returned after their socket closes, including results arriving after the service relay timeout, enter the same bounded revocation drain.
- The bounded runner owns only the Bun, Caddy, and `cloudflared` child processes it launches. It accepts a 60–3600 second lifetime and defaults to 30 minutes. It does not alter Tailscale, DNS, account settings, or unrelated listeners.

Service evidence is covered by 33 local Bun tests. Those tests include a real cross-process add/revoke race, simultaneous writers against an unchanged stale lock, malformed-lock fail-closed behavior, live approval revocation of both sockets, signaling termination, room removal, two-peer TURN revocation and shutdown drain, revocation during pending TURN issuance, approval/retry, rejection before pending-room creation for an invalid host token, phone-before-host reconnect semantics, real-provider contract mocks, bounded shutdown revocation, late issuance after socket close and timeout, provider timeout and malformed-response failures, global issuance limits, room expiry, peer limits, message limits, and private-file checks.

## Current provider facts

Cloudflare's current credential API returns short-lived ICE credentials from `POST /v1/turn/keys/{key}/credentials/generate-ice-servers`; the long-lived TURN key remains on the server. Cloudflare documents per-credential revocation with a `POST` that returns 204. Credentials may be issued for at most 48 hours, while this package limits them to at most 24 hours and uses one hour in the example. [Generate credentials](https://developers.cloudflare.com/realtime/turn/generate-credentials/) · [TURN FAQ](https://developers.cloudflare.com/realtime/turn/faq/)

Cloudflare currently documents TURN at USD 0.05 per outbound real-time GB after a 1,000 GB free tier. Ingress and STUN are not charged under that description. This is a current provider statement, not a cost guarantee for PocketDesk. [TURN pricing](https://developers.cloudflare.com/realtime/turn/faq/)

TURN analytics are available through Cloudflare's GraphQL API and include ingress bytes, egress bytes, and concurrent connections, filterable by TURN key and username. Cloudflare recommends separate test and production TURN keys and monitoring for credential abuse. [TURN analytics](https://developers.cloudflare.com/realtime/turn/analytics/) · [Provider monitoring guidance](https://developers.cloudflare.com/realtime/turn/replacing-existing/)

Cloudflare budget alerts are informational and do not stop usage. There is no provider-enforced byte or dollar cutoff established in this repository. For this bounded test, the effective controls are one dedicated test key, four maximum WebSocket peers, eight credential issuances per minute, a 30-minute process lifetime enforced by the bounded runner (the 30-minute room lease is extended by current apps while they stay connected, so it is no longer a cost cap; `SESSION_RENEWAL=0` restores it), file-revocation auditing every second, disconnect credential revocation, and deletion of the test TURN key after evidence is collected. Account billing alerts should be configured before any longer-running beta, but they are not a hard cap. [Budget alert behavior](https://developers.cloudflare.com/billing/manage/budget-alerts/)

## Local deployment inventory

| Item | Current result |
|---|---|
| Bun | Installed: 1.3.14 |
| Caddy | Installed: 2.11.4 |
| `cloudflared` | Installed from official Homebrew: 2026.9.1; no service, login, tunnel, or public route activated |
| Cloudflare local tunnel certificate/config | Not present in the standard checked paths |
| Cloudflare TURN/API environment variables | Not present in this task environment |
| Fly CLI | Installed, but read-only identity check reports no access token |
| Wrangler | Not installed |
| Project deployment manifest | None existed before this package; standalone examples now live under `Server/` |
| Public DNS/hostname | No project-specific hostname or zone access established |

No Cloudflare account was created or configured, no login was performed, no TURN key was created, no DNS was changed, and no service was published during this work. `cloudflared` 2026.9.1 is installed locally, but it has not been started or configured for PocketDesk. The parent's current Bun/Caddy/Tailscale physical-test processes and ports were not touched.

## Exact live gate

1. Supply an existing Cloudflare account authorized for Realtime TURN. Decide explicitly whether enabling this usage-based service is acceptable. Create a dedicated test TURN key and retain its key ID and server-only API token outside the repository.
2. Review the already-installed `cloudflared` 2026.9.1 binary before use. For a later explicitly approved temporary experiment, no Cloudflare login or owned domain is required for Quick Tunnel. A stable named tunnel additionally needs account access, a managed tunnel credential, and a hostname in a suitable DNS zone.
3. Create a mode-600 production environment file from `Server/.env.standalone.example` and an empty mode-600 approved-room file outside the repository. Leave the pending-room path absent; the service creates it with mode 600 in an existing private directory.
4. Run `bun run readiness --env-file /absolute/private/path/pocketdesk.env`. A passing result confirms actual credential issuance, the native ICE bounds, and credential revocation. It still does not allocate a relay or move media.
5. From `Server/`, start the bounded runner with the private environment, `Caddyfile.standalone.example`, `quick`, and `1800`. Read the generated `trycloudflare.com` hostname from its private run log and use `wss://<hostname>/signal` in PocketDesk Host.
6. On the Mac, choose the display and click **Pair a phone** once. Compare its `room_pending_<fingerprint>` status with `bun run approve-room list`, approve that exact fingerprint locally, then click **Enable remote access** so the same room registers. Scan the newly visible code on the phone and approve it on the Mac.
7. Put the iPhone on cellular with Wi-Fi disabled. With Relay-only off, confirm a changing desktop and a reflected text edit; record the route diagnostic. Then enable **Relay-only test**, reconnect, require the diagnostic to say `Relay`, and repeat useful video/control plus interruption recovery. A WSS pass alone is not TURN proof, and ordinary cellular success may still be a direct ICE route.
8. Run the readiness command again with `--wss` to capture public authentication and returned-ICE evidence. Stop the bounded runner, revoke the room fingerprint, verify its three owned child processes exited, and delete the dedicated TURN key if the test is complete. Review provider TURN analytics for the test interval and retain only redacted receipts.

## Remaining blockers

- `cloudflared` is installed but has no PocketDesk service, account session, tunnel, or public activation.
- No Cloudflare TURN key ID or server-only key token is available. A real credential request and revocation therefore cannot be run yet.
- Cloudflare account setup and the billing decision are explicitly deferred. The published free tier does not itself authorize enabling a metered provider.
- No stable DNS zone or tunnel credential is available for a named WSS endpoint. The already-approved temporary Quick Tunnel remains the only prepared no-domain route.
- Real TURN allocation, cellular route selection, forced-relay media/control, practical responsiveness, provider analytics, and cleanup are unobserved. They remain separate from WSS signaling readiness.

## Focused manifest

| Path | Purpose |
|---|---|
| `Server/src/rooms.ts` | Private reloadable approvals and bounded pending fingerprints |
| `Server/scripts/approve-room.ts` | Local list/approve/revoke workflow |
| `Server/scripts/readiness.ts` | Actual credential, client-limit, revocation, and optional public-WSS check |
| `Server/scripts/run-bounded-standalone.sh` | Owned-process supervisor for Bun, Caddy, and tunnel; stops them after its duration (30 minutes by default, up to 60), so pass a longer duration for a session-length test |
| `Server/.env.standalone.example` | Four-peer standalone test configuration with a 30-minute room lease and session renewal on |
| `Server/Caddyfile.standalone.example` | Loopback-only `/signal` route on dedicated ports |
| `Server/cloudflared.standalone.yml.example` | Stable named-tunnel template for later review |
| `Server/src/config.ts` | Production approval, issuance, and room-lifetime settings |
| `Server/src/index.ts` | Runtime entrypoint with bounded asynchronous signal shutdown |
| `Server/src/server.ts` | Approval gate, credential issuance brake, room expiry, disconnect cleanup |
| `Server/src/turn.ts` | Cloudflare short-lived credential revocation |
| `Server/tests/server.test.ts` | Service security, bounds, approval, cleanup coverage |
| `Server/tests/readiness.test.ts` | Readiness output and private environment-file coverage |
| `Server/tests/rooms.test.ts` | Cross-process mutation race plus stale/malformed-lock fail-closed coverage |
| `Server/tests/fixtures/room-mutation-worker.ts` | Independent process used by the room-file race test |
| `Server/standalone-source-manifest.json` | SHA-256 review boundary for this package |
