# PocketDesk relay deployment runbook: Cloudflare tunnel and Realtime TURN

Prepared 28 September 2026. **Nothing described here has been activated.** No login, account, key, DNS change, purchase, tunnel, or public exposure was made while preparing it. Engineering document, subordinate to [PRODUCT.md](../../../PRODUCT.md); it supersedes the Cloudflare parts of the 15 September deployment packet and extends [STANDALONE-NETWORK-READINESS.md](../../STANDALONE-NETWORK-READINESS.md) and [NETWORK-AND-SESSION.md](../2026-09-28/NETWORK-AND-SESSION.md).

Roshan approved Cloudflare (named tunnel plus Realtime TURN) as the relay provider. Creating accounts, buying domains, logging in, creating keys, changing DNS, accepting terms, and exposing a service publicly stay his own actions, or an explicit per-step go-ahead in chat.

## 1. What is being deployed

```
iPhone (cellular) ── wss://PD_PUBLIC_HOST/signal ──▶ Cloudflare edge ──▶ cloudflared (Mac, outbound only)
                                                                              │ only ^/signal$ is routed
                                                                              ▼
                                                              Bun signaling service 127.0.0.1:28787
                                                                              │ short-lived credential per peer
                                                                              ▼
                                                   Cloudflare Realtime TURN API (server side, key in Keychain)

iPhone ◀──────── WebRTC media and control (DTLS) ────────▶ Mac
        direct if ICE finds a path, otherwise through turn.cloudflare.com
```

- The tunnel carries only signaling JSON. The signaling payloads are already AES-GCM sealed end to end between the two apps, so Cloudflare relays opaque bytes. Media never crosses the tunnel. That also keeps this within Cloudflare's rule that Free, Pro and Business plans must not proxy video through a public hostname.
- The Mac needs outbound access to Cloudflare on port 7844 (TCP and UDP). The iPhone needs nothing but HTTPS/WSS and UDP or TLS to `turn.cloudflare.com`.
- Only `^/signal$` on the relay hostname is public. `/health`, `/ready`, `/browser-*` and everything else answer 404 at the tunnel. The service listens on loopback only.
- The service and `cloudflared` run as two per-user launchd agents copied out of `~/Documents` (launchd agents cannot read `~/Documents` without extra privacy grants). Both are removable with one command.

The native apps already accept any `wss://host/signal` service address (the Mac's setup screen stores it and puts it in the pairing code; the phone uses the address from the code) and use whatever ICE servers the service delivers. This change adds one optional field, `policy`, to the `ice` message so a test can force relay-only ICE on both peers. Apps without the change ignore it.

## 2. Verified documentation (retrieved 28 September 2026)

| Topic | Source | Page dated | Used for |
|---|---|---|---|
| Realtime TURN overview | https://developers.cloudflare.com/realtime/turn/ | 25 Sep 2026 | Address `turn.cloudflare.com`; 3478/udp (443/udp alternate), 3478/tcp (80/tcp), 5349/tcp TLS (443/tcp); anycast to the nearest location; global network except China; per-allocation limits (>50-100 Mb/s, >5-10 kpps, >5 new peer IPs/s) |
| Create key, generate and revoke credentials | https://developers.cloudflare.com/realtime/turn/generate-credentials/ | 25 Sep 2026 | Key created in the dashboard or API and kept server side; `POST https://rtc.live.cloudflare.com/v1/turn/keys/$KEY_ID/credentials/generate-ice-servers` with `Authorization: Bearer $TOKEN` and `{"ttl": seconds}` returns 201 and `iceServers`; `POST .../credentials/$USERNAME/revoke` returns 204 |
| Create key by API | https://developers.cloudflare.com/api/resources/calls/subresources/turn/methods/create/ | retrieved 28 Sep 2026 | `POST /accounts/{account_id}/calls/turn_keys`, permission "Calls Write"; returns `uid` (32 characters) and `key` (64 characters). Not used by these scripts |
| Pricing, limits, IPv6, TCP relaying | https://developers.cloudflare.com/realtime/turn/faq/ | 14 Jul 2026 | US$0.05 per GB sent from Cloudflare to the TURN client after a free 1,000 GB per month; STUN free; credential TTL at most 48 hours; expiry ends the allocation shortly after; relay addresses are IPv4 only; RFC 6062 TCP relaying unsupported; analytics lag about 30 seconds |
| Shared free allowance | https://developers.cloudflare.com/realtime/sfu/platform/pricing/ | 22 Sep 2026 | The 1,000 GB is shared by SFU and TURN and shows as one Realtime line item |
| Keys, environments, analytics | https://developers.cloudflare.com/realtime/turn/replacing-existing/ and https://developers.cloudflare.com/realtime/turn/analytics/ | 5 Jun 2026, 3 Jun 2026 | Up to 1,000 keys per account; separate test and production keys; usage only through the GraphQL API (`callsTurnUsageAdaptiveGroups`, token permission "Account Analytics"); `customIdentifier` is documented only for the `/credentials/generate` endpoint, so it is not sent |
| Named tunnel commands | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/ | 25 Aug 2026 | `cloudflared tunnel login` (browser, writes `cert.pem`), `tunnel create NAME` (UUID and credentials JSON in `~/.cloudflared`), `tunnel route dns NAME HOST` (proxied CNAME to `UUID.cfargotunnel.com`), `tunnel run`; a zone on Cloudflare nameservers is a prerequisite |
| Tunnel configuration file | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/ | 1 Sep 2026 | `ingress` rules with per-rule `hostname` and Go-regex `path`, mandatory catch-all, `ingress validate` and `ingress rule URL` for offline checks |
| Tunnel as a macOS service | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/as-a-service/macos/ | 17 Apr 2026 | Built-in `cloudflared service install` uses `~/.cloudflared/config.yml`; this repo uses its own labelled launch agent instead so the service and tunnel are controlled together |
| WebSockets | https://developers.cloudflare.com/cloudflare-one/faq/cloudflare-tunnels-faq/ and https://developers.cloudflare.com/network/websockets/ | 16 Sep 2026, 14 Aug 2026 | Tunnel has full WebSocket support on all plans; Cloudflare closes a WebSocket after a period with no data in either direction (the value is not published) and recommends keepalive pings; restarts of Cloudflare servers can drop sockets |
| Connectivity | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/troubleshoot-tunnels/connectivity-prechecks/ | retrieved 28 Sep 2026 | Outbound TCP and UDP 7844; `cloudflared` falls back between QUIC and HTTP/2 |
| Quick Tunnel | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/ | 20 Apr 2026 | Random `trycloudflare.com` host, no domain, testing only, 200 in-flight requests, no SSE, not usable while `~/.cloudflared/config.yaml` exists |
| Certificates | https://developers.cloudflare.com/ssl/edge-certificates/universal-ssl/limitations/ | retrieved 28 Sep 2026 | Universal SSL covers the apex and first-level subdomains only, so use `relay.your-domain`, not `a.relay.your-domain` |
| Registering a domain | https://developers.cloudflare.com/registrar/get-started/register-domain/ | 24 Apr 2026 | Dashboard, Register domains; contact details, payment and agreements are accepted by the buyer; Cloudflare nameservers are automatic; verified account email required |

Local read-only checks the same day: `cloudflared` 2026.9.3 installed, no `~/.cloudflared` directory (not logged in, no tunnel). `tailscale serve status` shows an unrelated Funnel on `:8443` and tailnet-only routes on `:443`, `:10000` and `:8444` (including `/signal` to `127.0.0.1:18787`); none of it was touched and the relay uses port 28787, which none of them use.

Not established by documentation: whether the dashboard demands a payment method or terms acceptance before Realtime can be used (the free tier is documented; the enablement flow is not); the idle time after which Cloudflare closes a silent WebSocket. Both are handled as user decisions or acceptance checks below.

## 3. Choose the path

| Path | Needs | Public name | Use |
|---|---|---|---|
| **A. Quick Tunnel, no domain** | Cloudflare account and a TURN key only | Random `*.trycloudflare.com`, changes every run | First cellular and forced-relay acceptance test. Time-bounded by the existing runner (60 to 3600 s, default 30 min). No SLA |
| **B. Named tunnel on your domain** | A domain on Cloudflare DNS, `cloudflared tunnel login`, the TURN key | `relay.<your-domain>`, stable | Daily use. Can run as launch agents |

The domain is not decided yet, so A needs no decision. B takes one value, `PD_PUBLIC_HOST`, and nothing else in the repository names a domain.

## 4. Steps only you can do

Each block is one copy-paste step. Do them in order; stop after step 4 if you are starting with path A.

**Step 1. Sign in and verify your account email.** Cloudflare dashboard, https://dash.cloudflare.com/ . The account already exists; if the address is not verified, open the verification email (needed later for domains). Nothing to paste.

**Step 2. Create a TURN key.** Open https://dash.cloudflare.com/?to=/:account/calls , create a TURN key named `pocketdesk-relay-test`, and keep the page open. It shows a 32-character Key ID and a 64-character API token; the token is shown once. If the dashboard asks for a payment method or terms before Realtime can be used, that is your decision: the documented free tier is 1,000 GB per month, billing alerts are informational and do not stop usage (https://developers.cloudflare.com/billing/manage/budget-alerts/), and the real brake is deleting the key. Recommended: also set a budget alert of about US$5.

**Step 3. Store the Key ID in macOS Keychain.** Paste the Key ID at the prompt; it does not go on the command line or into your shell history.

```sh
security add-generic-password -U -a "$USER" -s pocketdesk.cloudflare.turn-key-id -w
```

**Step 4. Store the API token in macOS Keychain.** Paste the token at the hidden prompt (twice).

```sh
security add-generic-password -U -a "$USER" -s pocketdesk.cloudflare.turn-api-token -w
```

Check that both exist without printing them: `security find-generic-password -s pocketdesk.cloudflare.turn-key-id >/dev/null && security find-generic-password -s pocketdesk.cloudflare.turn-api-token >/dev/null && echo stored`. Never paste either value into chat. To replace a key later, use `Server/scripts/rotate-turn-key.sh`.

**Step 5 (path B only). Decide the hostname.** Pick one, then tell the agent the hostname (it becomes `PD_PUBLIC_HOST`):
- Buy a domain: dashboard, Register domains (https://dash.cloudflare.com/?to=/:account/registrar/register). You enter contact and payment details and accept the registration agreement. The retail price of a `.com` was about US$10.44 a year on 15 September 2026 and is expected to rise to about US$11.15 from November 2026 (the deployment packet's figure; confirm at checkout). Cloudflare nameservers are set automatically.
- Or add a domain you already own (dashboard, Add a domain, free plan) and change its nameservers at your registrar to the two Cloudflare gives you.
- Use a first-level subdomain such as `relay.your-domain`; the free certificate does not cover deeper names.

**Step 6 (path B only). Log `cloudflared` in.** This opens your browser; choose the zone. It writes `~/.cloudflared/cert.pem`, which can manage tunnels and DNS for that zone, so keep it private and never share it.

```sh
cloudflared tunnel login
```

**Step 7 (physical, for the test). Prepare the iPhone.** Turn Wi-Fi off and turn any VPN off, including Tailscale (Settings, VPN). A connected VPN makes the test meaningless.

**Step 8. Give the go-ahead for public exposure.** Path A: when you start the bounded runner. Path B: before the publish command in section 5.B step 5. Say so in chat; the scripts will not create DNS or start the public tunnel without it.

**Afterwards (only you can):** delete the relay hostname's CNAME in the dashboard if you tear it down, and delete the TURN key (Realtime, TURN) when the test is over or when rotating. The teardown script prints these reminders.

## 5. Steps an agent can run after your steps

All commands run from the repository's `Server/` directory. Nothing below prints a secret; the readiness output contains only counts, names and pass/fail.

### A. Quick Tunnel (no domain)

1. `bun scripts/relay-env.ts init` creates `~/.pocketdesk/relay/relay.env` (mode 600, non-secret values, Keychain as the secret source) and an empty `approved-rooms` file.
2. `bun scripts/readiness.ts --env-file ~/.pocketdesk/relay/relay.env --offline` validates configuration, permissions and the Keychain items with no network.
3. `bun scripts/readiness.ts --env-file ~/.pocketdesk/relay/relay.env` makes one real credential request and revokes it; expect `"revoked": "confirmed"`. This is the first contact with the Cloudflare API and needs steps 1 to 4 above.
4. After your go-ahead: `./scripts/run-bounded-standalone.sh ~/.pocketdesk/relay/relay.env "$PWD/Caddyfile.standalone.example" quick 1800`. Read the hostname with `grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' <log directory it prints>/tunnel.log | head -1` and use `wss://<that host>/signal` in PocketDesk Host. The runner owns and cleans up only its own processes.

### B. Named tunnel

1. `bun scripts/relay-env.ts init --host relay.<your-domain>` (add `--tunnel-name NAME` to change the default `pocketdesk-relay`).
2. `bun scripts/readiness.ts --env-file ~/.pocketdesk/relay/relay.env` (offline first with `--offline`, as above).
3. `./scripts/deploy-cloudflare.sh` (dry run, changes nothing) prints the plan and validates the rendered ingress with the installed `cloudflared`. It exits 78 and lists what is missing if the environment file, Keychain items, or `~/.cloudflared/cert.pem` are absent.
4. `./scripts/deploy-cloudflare.sh --apply` creates the tunnel if it does not exist (an account change), renders `~/.pocketdesk/relay/cloudflared.yml` and both launch agents, starts the signaling agent on loopback, and runs the live readiness check. It stops before anything public.
5. After your go-ahead: `POCKETDESK_APPROVE_PUBLIC=yes ./scripts/deploy-cloudflare.sh --apply` creates the DNS record (`cloudflared tunnel route dns`, a proxied CNAME to `<tunnel-uuid>.cfargotunnel.com`), starts the tunnel agent, and runs `bun scripts/readiness.ts --env-file ... --public`, which checks that `/health`, `/ready`, `/`, `/browser-host` and `/api/diagnostics` are not reachable through the tunnel and that a synthetic authenticated host and phone receive real ICE servers.
6. Pair: in PocketDesk Host enter `wss://relay.<your-domain>/signal`, click Pair a phone, note the `room_pending_<fingerprint>`, then `bun run approve-room list --approved-file ~/.pocketdesk/relay/approved-rooms --pending-file ~/.pocketdesk/relay/pending-rooms.json` and `bun run approve-room approve --approved-file ~/.pocketdesk/relay/approved-rooms --pending-file ~/.pocketdesk/relay/pending-rooms.json --fingerprint <12 hex>`. Click Enable remote access, scan the code, approve on the Mac. The service re-reads the approval file every second; no restart is needed.
7. Monitor: `curl -s http://127.0.0.1:28787/ready` (200 and `"status":"ready"`), `tail -f ~/Library/Logs/PocketDesk/relay-signal.log`, `tail -f ~/Library/Logs/PocketDesk/relay-tunnel.log`, `launchctl print gui/$(id -u)/com.pocketdesk.relay.signal`. Use the approve-room `revoke` action to cut off a phone within one second.
8. Stop or remove: `./scripts/teardown-cloudflare.sh` (dry run) then `--apply`; add `--delete-tunnel`, `--purge-secrets`, `--purge-files` as needed. It stops the tunnel first, then the service, then verifies nothing still listens. Rotate a key with `./scripts/rotate-turn-key.sh` (dry run) then `--apply`.

### Limits, kept and justified

| Setting | Value | Why |
|---|---|---|
| `TURN_CREDENTIAL_ISSUES_PER_MINUTE` | 8 (kept) | Each session issues two credentials (Mac and phone), so 8 admits four session starts a minute. Reconnect storms hit the cap and fail with `relay_unavailable` instead of running up issuance. It is a process-wide brake and does not meter relayed bytes |
| `MAX_PEERS` | 4 (kept) | One Mac, one phone, and a reconnect margin. This counts open sockets, so a stale socket plus a retry can briefly use three |
| `TURN_CREDENTIAL_TTL_SECONDS` / `ROOM_LIFETIME_SECONDS` | 3600 / 1800 (kept for acceptance) | The room must end before the credential does because credentials are not refreshed mid-session. A signaling close tears the media session down |
| Credential revocation | on every disconnect | TTL expiry is only the backstop; Cloudflare stops billing when a credential expires or is revoked |
| Credential requests | 3 s timeout, bounded responses, at most 8 servers and 8 URLs each | Existing client limits. Cloudflare currently returns six TURN URLs in one server entry |
| Daily-use profile | `TURN_CREDENTIAL_TTL_SECONDS=10800`, `ROOM_LIFETIME_SECONDS=7200` | Apply only after the acceptance test. A session cannot outlive its room, so it can end at the room boundary; the Mac re-registers automatically. Preflight warns above six hours. Change with `bun scripts/relay-env.ts set KEY VALUE --env-file ...` and restart |

The connection-attempt limit is counted per observed source address and every request arrives from the local `cloudflared`, so the 20 per minute in the template is one shared bucket. That suits one owner; it is not a per-user limit.

## 6. Cost estimates

Only TURN egress is metered: data from Cloudflare to the TURN client at US$0.05 per GB after 1,000 GB per month, account-wide and shared with any SFU use (none here). The tunnel is not billed. Cloudflare's TURN FAQ and pricing page are the source; treat all numbers as a planning model, not a quote.

Video is counted once per relayed session. When both peers relay, the Mac's 8 Mb/s uplink enters Cloudflare as free ingress and leaves toward the phone as billed egress; the reverse direction (input, acknowledgements) is a few kilobits.

Formula: billed GB per user per month = Mb/s ÷ 8 × 3600 × hours per month ÷ 1000 × share of time relayed × 1.10 overhead (decimal GB). Cost = max(0, users × GB − 1000) × 0.05.

| Scenario | GB/user/month | 50 users | 500 users | 5,000 users |
|---|---:|---:|---:|---:|
| Planning model in NETWORK-AND-SESSION.md: 8 Mb/s, 20 h, 30% relayed | 23.76 | 1,188 GB, $9.40 | 11,880 GB, $544 | 118,800 GB, $5,890 |
| Lighter: 4 Mb/s, 10 h, 30% relayed | 5.94 | 297 GB, $0 | 2,970 GB, $98.50 | 29,700 GB, $1,435 |
| Worst case: 8 Mb/s, 20 h, 100% relayed | 79.20 | 3,960 GB, $148 | 39,600 GB, $1,930 | 396,000 GB, $19,750 |

Your own use (one user): 8 Mb/s, 3 h a day, fully relayed is about 356 GB a month, inside the free tier, so US$0.

Also, path B costs a domain (about US$10 to 12 a year, a purchase you make) and nothing for the tunnel. Path A costs nothing beyond the free tier.

Not in the table: signaling hosting, monitoring, taxes, support and payment fees. Signaling on this Mac is a single-owner design; at hundreds of users it moves to hosted infrastructure and must be priced separately. Video bitrate and hours dominate: halving the bitrate halves the bill. An annual unlimited promise needs measured relay share and bitrate first.

## 7. Cellular and forced-relay acceptance test

Status: **not run.** Cellular reachability, WSS certificate acceptance, real TURN allocation, forced-relay media and control, responsiveness, and provider analytics are unobserved. Do not report any as passed until the receipts below exist.

**Preconditions.** Mac awake and unlocked with Screen Recording and Accessibility granted; PocketDesk Host and the phone app built from this branch (so both honor `policy`); relay running (path A or B); steps 1 to 4 and 7 done; the phone on cellular only with all VPNs off; the Mac on a different network from the phone if possible.

| # | Test | How | Pass evidence |
|---|---|---|---|
| 1 | Service ready | `curl -s http://127.0.0.1:28787/ready` and `bun scripts/readiness.ts --env-file ~/.pocketdesk/relay/relay.env` (add `--public` on path B) | `ready`, `"policy":"all"`, credential issued and revoked |
| 2 | Pair over the internet | Pairing steps in section 5.B.6 (path A: use the `trycloudflare` URL) | Phone shows the Mac and enrolls with Wi-Fi off |
| 3 | Ordinary session | Connect from cellular; watch the desktop change, type a line into a text editor, click a button | Live changing video and a reflected edit. Record the route in Connection Details (`Direct` or `Relay`; either is acceptable here) |
| 4 | Forced relay | `bun scripts/relay-env.ts set POCKETDESK_TEST_FORCE_RELAY 1 --env-file ~/.pocketdesk/relay/relay.env`, then `launchctl kickstart -k gui/$(id -u)/com.pocketdesk.relay.signal` (path A: restart the runner). Confirm `"policy":"relay"` in `/ready`. Disconnect and reconnect from the phone | Connection Details says `Relay`; video and control still work; repeat a 5 minute mixed reading and typing session and note lag and freezes |
| 5 | Both sides forced | Same run with the phone's own Relay-only toggle off, so only the service policy is forcing relay | Still `Relay`. If the phone was older than this branch the policy is ignored and the route can be `Direct`; that means the build is stale, not that relay works |
| 6 | Interruption | With a live session, toggle Airplane Mode on for 10 seconds, then off | The app reports interruption and retries within its bounded retry (about 15 seconds of backoff); it reconnects without replaying any input; if it gives up it says so |
| 7 | Idle | Leave the Mac registered and idle for 10 minutes, then connect | Connection succeeds without restarting anything (checks Cloudflare's idle WebSocket close against the service's ping keepalive) |
| 8 | Room expiry | Stay connected past the room lifetime (30 minutes, or the daily profile) | The session ends at the boundary by design; the Mac re-registers and a new connection works |
| 9 | Provider usage (optional) | Cloudflare GraphQL analytics, dataset `callsTurnUsageAdaptiveGroups`, filtered to the test window; needs an API token with "Account Analytics" that you create and keep out of chat. Data appears within about 30 seconds | Egress bytes roughly match the session length times bitrate for the forced-relay run |
| 10 | Cleanup | `bun scripts/relay-env.ts set POCKETDESK_TEST_FORCE_RELAY 0 --env-file ...` and restart; `bun run approve-room revoke ... --fingerprint <12 hex>` for test phones; `./scripts/teardown-cloudflare.sh --apply` (add `--delete-tunnel` if finished) | No listener on the port, no relay `cloudflared` process; you delete the DNS record and the test TURN key |

Fail conditions to record instead of fixing silently: certificate or WSS failure on the phone; `relay_unavailable` on registration (provider or issuance limit); a forced run that shows `Direct`; video without control or the reverse; a session that dies before the room lifetime; a key or token appearing anywhere in a log or a screenshot (rotate immediately with `rotate-turn-key.sh`). Keep only redacted receipts: dates, the route shown, byte counts, and pass or fail.

## 8. What was and was not verified while preparing this

Verified locally: the server test suite (all tests, including the new ones with a mocked Cloudflare API and stubbed system tools); the macOS Swift test bundle including real signaling and WebRTC integration tests (run from a copy outside `~/Documents` because the test host is denied access to files under `~/Documents`); the rendered `cloudflared` ingress, evaluated by the installed `cloudflared` 2026.9.3, routes only `/signal` and answers 404 for `/`, `/health`, `/ready`, `/browser-host` and `/signal/extra`; the deploy, teardown and rotate scripts in dry-run and, against stubs, in apply mode.

Not verified: any request to the real Cloudflare API, tunnel creation, DNS, certificates, launch-agent operation with a real Keychain (expected to work when you are logged in and the login keychain is unlocked; check with `launchctl kickstart` and `/ready`), an iPhone on cellular, or a forced-relay route. The relay stops when the Mac sleeps, locks the login keychain, or logs out; awake and unlocked remains the supported host state.
