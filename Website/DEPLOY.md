# Deploying getfarside.com

Cloudflare Pages project `farside-site` serves `dist/` plus two Pages Functions backed by the D1 database `farside-waitlist` (binding `WAITLIST`, see `wrangler.jsonc`). Run everything from `Website/` with `bunx wrangler@4`.

## Waitlist API (contract for the `#beta` form)

`POST /api/waitlist` with JSON `{"email", "source", "company": ""}` or a plain form post with the same field names. `company` is a honeypot and must stay empty and hidden.

| Result | JSON (`Content-Type: application/json`) | Form post |
|---|---|---|
| Joined (also repeat sign-ups and honeypot hits) | 200 `{"ok":true}` | 303 → `/?joined=1#beta` |
| Bad address | 400 `{"ok":false,"error":"invalid_email"}` | 303 → `/?joined=0&error=invalid_email#beta` |
| More than 5 tries per IP in 10 minutes | 429 `rate_limited`, `Retry-After: 600` | 303 → `…error=rate_limited#beta` |
| Cross-site post | 403 `forbidden` | 303 → `…error=forbidden#beta` |

`source` is `[a-z0-9_-]{1,40}` (for example `home`, `x-bio`, `ig-bio`); anything else is stored as `site`. The consent version stored with each row is `CONSENT` in `functions/api/waitlist.ts`; bump it whenever the wording beside the form changes. The wording must say what people will get (a beta invite and launch news) and that they can unsubscribe at any time.

Unsubscribe links in emails: `https://getfarside.com/api/unsubscribe?t=<unsubscribe_token>`. Opening the link only shows a button; the POST behind the button unsubscribes (link scanners can't unsubscribe anyone).

## First-time setup (needs the owner's Cloudflare login)

```sh
bunx wrangler@4 login                                   # browser: approve access to the Cloudflare account
bunx wrangler@4 d1 create farside-waitlist --location enam   # done 29 Sep; id is in wrangler.jsonc
bunx wrangler@4 d1 migrations apply farside-waitlist --remote
bunx wrangler@4 pages project create farside-site --production-branch main
openssl rand -hex 32 | bunx wrangler@4 pages secret put RATE_SALT --project-name farside-site
```

## Deploy

```sh
bun run build                                           # preview: placeholders allowed
bunx wrangler@4 pages deploy dist --project-name farside-site --branch preview   # → https://preview.farside-site-dgk.pages.dev (noindex)

bun run build:strict                                    # production: fails until site.config.ts contacts are filled
bunx wrangler@4 pages deploy dist --project-name farside-site --branch main
```

Custom domain (production only, after the owner approves the site): Workers & Pages → `farside-site` → Custom domains → add `getfarside.com` and `www.getfarside.com`, then redirect `www` to the apex with a Bulk Redirect.

## Local development

```sh
bunx wrangler@4 d1 migrations apply farside-waitlist --local
bun run build && bunx wrangler@4 pages dev dist --port 8788
bunx wrangler@4 types --path edge/worker-configuration.d.ts && bunx tsc -p edge/tsconfig.json   # typecheck the functions
```

## Reading the list

```sh
bunx wrangler@4 d1 execute farside-waitlist --remote --json \
  --command "SELECT email, source, created_at FROM waitlist WHERE unsubscribed_at IS NULL ORDER BY id"
```

Delete test rows before launch: `--command "DELETE FROM waitlist WHERE email LIKE '%@example.%'"`.
