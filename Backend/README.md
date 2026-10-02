# Farside backend (Cloudflare Workers)

Production signaling, relay credentials and the subscription entitlement gate. Design: [DESIGN.md](DESIGN.md). Phone-facing contract: [ENTITLEMENT-CONTRACT.md](ENTITLEMENT-CONTRACT.md). Wire protocol: [`Docs/REMOTE-PROTOCOL.md`](../Docs/REMOTE-PROTOCOL.md). The Bun service in [`Server/`](../Server) remains the local/dev reference.

```sh
bun install
bun run test          # vitest inside workerd: real WebSockets, Durable Object storage, D1
bun run typecheck
cp .dev.vars.example .dev.vars   # fill in local secrets (git-ignored)
bun run dev           # wrangler dev on http://127.0.0.1:8787 (ws://127.0.0.1:8787/signal)
bun scripts/load-test.ts --url ws://127.0.0.1:8787/signal --rooms 50
bun run check         # wrangler deploy --dry-run --env staging
```

Deploy steps, secrets and environments: DESIGN.md §8 and §13. Nothing here deploys or creates Cloudflare resources on its own.

Operational acceptance, alert thresholds, retention and rollback notes: [RUNBOOK.md](RUNBOOK.md). `scripts/load-test.ts` requires `route.1` for public targets; free rooms may run concurrently, while entitlement-backed rooms are serialized automatically to respect one live room per paid device. Supply one token via `FARSIDE_LOAD_ENTITLEMENT_TOKEN` or `--token`, or one distinct token per room as a JSON array via `FARSIDE_LOAD_ENTITLEMENT_TOKENS` or `--tokens`. Tokens and URL credentials/query values are never printed.
