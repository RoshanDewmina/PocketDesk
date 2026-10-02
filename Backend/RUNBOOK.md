# Backend operations runbook

This runbook describes review and acceptance steps. Running a deploy, changing a secret, switching a production variable, or rolling back requires separate authorization. Do not paste secret values into logs, tickets, shell history, or this runbook.

## Before each rollout

Record the target environment, Worker name, deployed version ID and percentage, migration names applied, non-secret variable names and values, secret names with present/missing status only, `/health`, and authenticated `/ready` result. Save redacted output with the lane receipt. Confirm the active custom domain and that no preview URL or `workers.dev` route is exposed.

`ALLOW_UNENTITLED_RELAY=1` is forbidden on staging and production; startup validation rejects it. Never use that switch to test paid relay. `DEV_RELAY_ROOMS` is allowed only for an explicitly staged exception, is limited to four room IDs, and is refused in production. Keep it unset for paid-path acceptance. `ALLOW_XCODE_TRANSACTIONS` is dev/test only.

The production receipt records Worker `farside-backend-production`, custom domain `signal.getfarside.com`, D1 `farside-entitlements-production`, and migrations `0001`–`0006` applied at initial deployment. Version `28e8b088-cc90-45f0-815e-42c0125924d3` was 100% after that deploy. Its initial secret names were `ENTITLEMENT_TOKEN_KEY`, `ENTITLEMENT_HASH_KEY`, `ADMIN_TOKEN`, and `APPLE_ROOT_CERTS`; the lane handoff later reports `APNS_TEAM_ID`, `APNS_KEY_ID`, and `APNS_PRIVATE_KEY` were set at 08:45 Toronto time, creating a subsequent version whose ID is not in that receipt. The receipt also says the production TURN key pair was not configured at that time. Do not treat `28e8b088` as the current version or roll back to it without restoring later secrets; verify the deployed version and secret presence read-only first. Never record secret values. Production `KEEPALIVE_SECONDS=0` and staging `KEEPALIVE_SECONDS=50` remain different; staging's current idle result does not prove production idle behavior.

## Production-shaped staging acceptance

Use the staging service and a real sandbox purchase/token. Match production policy: `ENVIRONMENT_NAME=staging`, `ALLOW_XCODE_TRANSACTIONS=0`, `ALLOW_UNENTITLED_RELAY=0`, no `DEV_RELAY_ROOMS`, strict rate limits on, TURN analytics and circuit breaker on, issuance kill switch off. Keep `SUBSCRIPTION_RECOVERY_ENABLED=0` until the Apple API credentials/dependencies and privacy notice review are complete; then set it to `1` only for the dedicated recovery acceptance. Enable `TEST_FORCE_RELAY=1` only for the forced-relay scenario; it is refused in production. Do not treat a development room or unsigned transaction as a paid result.

Run and record all of these with disposable test data:

1. Pair without a sandbox entitlement and confirm local access only, with no TURN ICE server. Pair with a sandbox entitlement and confirm relay credentials are delivered to both peers and route policy is relay-only for the forced-relay scenario.
2. Keep a forced-relay session alive for at least 45 minutes. Confirm the session remains connected across multiple lease renewals and credential refreshes, then Stop Sharing and confirm credentials are revoked.
3. Refund the sandbox purchase. Confirm the signed notification or recovery cursor applies the refund, live access is revoked within one five-minute entitlement check interval, and a subsequent verification does not restore access. Also exercise unlink and natural expiry; each must prevent new relay credentials and end any live paid route at its next authoritative check.
4. Test a quiet session first with the production value `KEEPALIVE_SECONDS=0`, then separately with staging's current 50-second value. Observe a minimum 10-minute idle interval and a 45-minute session. Record whether both peers stay connected and whether a Mac sleep/wake changes the result. The 50-second run cannot stand in for the production-shaped zero setting.
5. Confirm TURN analytics groups egress by the entitlement pseudonym in `customIdentifier`. Compare the provider's egress byte total per identifier with the exact sum over the tested window. TURN issuance logs report attribution/issuance outcomes only; they are not egress measurements. A missing identifier, unsupported provider field, or unavailable byte metric leaves per-entitlement egress acceptance open.
6. For recovery acceptance, use Apple sandbox and production API credentials in staging only. Confirm the first history windows cover 29 days for Sandbox and 179 days for Production, each leaving one day inside Apple's 30/180-day limit; each minute tick must make no more than one history-page request per configured environment and four subscription-status lookups total, with cooperative budget checks between work items at 45 seconds. This is not a hard wall-clock bound, and one-time and consent-stop notification paths retain their existing immediate RPC behavior. Replay a missed refund and confirm revocation delivery. Record API status/counts, cursor age, and outcomes without transaction IDs or signed payloads.

Keep the sandbox transaction, room, token, TURN username/credential, device token, and raw subscription identifier out of saved output. Retain only redacted test timestamps, outcome codes, version IDs, aggregate timings/bytes, and pseudonymous entitlement identifiers where needed for the provider query.

## Alerts and response thresholds

These are initial operator thresholds to tune against real traffic; Workers Logs do not themselves provide a durable metric store. Build the alert query/dashboard from structured events and provider analytics, and retain only aggregates.

| Signal | Page/alert threshold | First check |
|---|---|---|
| `/v1/entitlements/verify` availability or storage failures | 5% or more failures over 5 minutes with at least 20 attempts; immediate alert for 5 consecutive dependency failures | Apple status/API health, D1 availability, `verify_unavailable` / `verify_storage_failed`, recovery cursor age |
| Public room registration failures | 5% or more service failures over 5 minutes with at least 20 attempts; exclude expected `unauthorized`, `entitlement_required`, and rate-limit responses | `room_status_lookup_failed`, `device_room_claim_failed`, `entitlement_lookup_failed`, `relay_issue_failed`, and recent Worker version |
| Apple/D1/provider timeout failures | 3 consecutive failures or 5 within 5 minutes per dependency | Provider status, timeout/error class, D1 health; do not include request bodies or credentials in evidence |
| Pending TURN revocations | Any credential still pending more than 5 minutes; urgent review if oldest age exceeds 30 minutes or is within 10 minutes of credential expiry | Retry queue count/oldest age, revoke result, and whether TTL has expired; never export usernames |
| TURN issuance circuit breaker | Any open circuit lasting beyond its 30-second cooldown, or repeated openings twice in 10 minutes | Provider failures, issuance disabled flag, secret presence status, and whether a half-open probe succeeded |
| TURN egress | Alert at 70% and 90% of the monthly account allowance; page on unexplained growth above twice the seven-day daily average | Cloudflare bytes grouped by `customIdentifier`, entitlement-level aggregate, and relay-session count |

Do not estimate egress by multiplying issuance events by a bitrate assumption. The stream can vary up to the app's configured ceiling, and TURN issuance does not reveal whether media selected relay or how many bytes flowed.

## Recovery and rollback record

Before a rollout, record the last known good version ID and the exact migration list for that environment. Migrations are additive/forward-only: application rollback does not reverse D1 migrations. Confirm the previous code can tolerate the current schema, and record any secrets changed since the last known good version so they can be restored through the approved secret workflow if needed. Rehearse against staging before relying on a production rollback procedure. Never roll production back to a version without required runtime secrets or re-enable a permissive flag to make a rollback work.

The recovery and TURN controls are independent. `SUBSCRIPTION_RECOVERY_ENABLED=0` disables Apple status recovery; `STRICT_RATE_LIMITS=0` restores permissive rate-limit failure behavior; `TURN_ANALYTICS_ENABLED=0` removes provider attribution; `TURN_CIRCUIT_BREAKER_ENABLED=0` attempts every issuance; `TURN_ISSUANCE_DISABLED=1` stops new credentials while revocation remains available; `PUSH_PAIRING_RETENTION_ENABLED=0` retains pairing hashes indefinitely. Set retention off before the one-year deadline if rollback may be needed; once an expired hash is deleted, the flag cannot recover it. Record any rollback flag change and restore the secure value as soon as the incident is resolved.

For an approved staging rollout that includes migration `0007`, apply D1 migration first, then deploy the Worker from `Backend/`:

```sh
bun x wrangler@4.143.0 d1 migrations apply farside-entitlements-staging --env staging --remote
bun x wrangler@4.143.0 deploy --env staging
```

For read-only version verification, use `bun x wrangler@4.143.0 versions list --env <environment>` and record the actual current version before planning a rollback. Run checks only after recording the resulting staging version ID and verifying `/health` and authenticated `/ready`. Apply and test the same code/schema change on production only under a separate explicit production authorization. Before rollback, read the current version list and secret-presence inventory. Use only a verified last-known-good version whose required secrets are still present; application rollback never rolls back D1 migrations. The original production version `28e8b088` predates the reported 08:45 APNs secret change and is not a safe rollback target until required secrets are restored.

## Local harness

The load harness advertises `route.1`, bounds room/signal/hold/concurrency arguments, redacts URL credentials/query/fragment, and closes all opened sockets in a bounded cleanup window. Free rooms can run concurrently. When an entitlement token is supplied, paid rooms run one at a time because each successful claim moves the device's single live-room pointer.

For a paid run, prefer `FARSIDE_LOAD_ENTITLEMENT_TOKEN` over `--token` so the token does not appear in the command line. The harness never prints the token. Keep public runs small and authorized; the harness cap is 250 rooms, 1,000 signal exchanges per room, 60 seconds hold per room, and 20 free rooms concurrently. Paid mode forces concurrency to one.

## Privacy and retained identifiers

Verified subscription recovery may store `subscription_original_transaction_id` for Apple status lookup. It is nullable, sourced only from a verified purchase, never logged or included in responses, and purged with its entitlement row (90 days after access ends). Previously hashed-only rows cannot be reversed; a later verified purchase/history result must seed them.

RoomDO `push_pairing` retains only the room and client-token hash needed to let an offline paired phone opt out of agent alerts. The row gets its own 365-day age from authenticated host registration. Alarm cleanup removes it after that cutoff only with no open sockets, unexpired lease, or unexpired route authority. Explicit forget, block, and phone replacement clear or rotate it sooner. The full APNs device token remains in D1 under the separate push-registration lifecycle.
