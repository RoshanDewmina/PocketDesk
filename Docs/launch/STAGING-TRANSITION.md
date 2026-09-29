# Staging transition for native acceptance — 29 September 2026

Prepared for review; nothing in this packet has been applied to Cloudflare.

The new native clients require authenticated `route.1` policy. The installed private Bun service does not provide it. Do not install these clients against that service or enable a legacy admission bypass. The preferred acceptance route is the existing staging Worker at `signal-staging.getfarside.com`, with fresh staging pairing and purchases disabled.

## Proposed external action

1. Record the current staging deployment and D1 recovery bookmark immediately before changes.
2. Apply the two pending migrations to **farside-entitlements-staging**, database `5b916903-865e-4659-b359-e8ef333167bd`: `0002_purchase_order.sql` adds `purchase_at` with a default to existing entitlement rows; `0003_agent_push.sql` creates pairing-scoped alert and session-activity tables/indexes. Neither migration deletes an existing table or row.
3. Deploy the reviewed integrated `Backend/` source as **farside-backend-staging**, using its existing bindings/domain. No production resources or new paid resources are part of this action.
4. Verify health, schema inventory, authenticated route negotiation, rejection of old clients, and denied unverified remote access before changing installed clients. Retain the previous deployment ID for Worker rollback; the additive schema can remain if the Worker is rolled back. A database restore would require a separate reviewed recovery decision.
5. Build/install from integrated main only. Preserve Mac signing/path/TCC. Pair through the staging service explicitly. This replaces the active private pairing; a rollback may require pairing again. Keep the old service available and do not export pairing or screen keys into receipts. Prove free LAN physically, then verify denied WAN/VPN. A policy snapshot alone must not admit free media or input.

The source passes the 127-test backend suite and TypeScript typecheck. The final local bundle dry run is recorded under `work/launch-preparation/staging-final-bundle*`. The earlier live staging health response is not proof that the current schema or protocol is deployed.

## Limits that this action does not resolve

- Numeric Apple app ID is still blank. Purchases remain disabled; paid sandbox acceptance is a separate gate.
- A fresh read-only staging secret-name inventory contains ADMIN_TOKEN, APPLE_ROOT_CERTS, both Cloudflare TURN bindings, and both entitlement keys. It contains no APNs provider secrets. Secret values were not read or exported. Real agent-alert delivery and suspended Live Activity end delivery remain blocked pending provider setup.
- Production D1/origin readiness, AASA hosting, distribution profiles/certificates, Sparkle signing, archives, notarization and publication remain separate actions.
- No provider deployment, migration, portal submission, or publication is authorized merely by the existence of this document. The owner must approve the concrete external action when these artifacts are ready.
