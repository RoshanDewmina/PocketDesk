import { json, methodNotAllowed, redirect, sameOrigin, sha256Hex } from "../../edge/respond";

interface Env {
  WAITLIST: D1Database;
  /** Secret salt for the rate-limit IP hash (`wrangler pages secret put RATE_SALT`). */
  RATE_SALT?: string;
}

/** Version of the sign-up wording shown beside the form. Bump it whenever that wording changes. */
const CONSENT = "waitlist-v2-2026-10-01";
const MAX_BODY_BYTES = 4096;
const WINDOW_SECONDS = 600;
const MAX_PER_WINDOW = 5;
const EMAIL = /^[^\s@<>()[\]\\,;:"]+@[^\s@<>()[\]\\,;:"]+\.[A-Za-z]{2,}$/;

type Fields = { email: string; source: string; company: string };
type Outcome = "joined" | "invalid_email" | "rate_limited" | "forbidden" | "too_large";

export const onRequestPost: PagesFunction<Env> = async ({ request, env }) => {
  const type = request.headers.get("Content-Type") ?? "";
  const wantsJson = type.includes("application/json") || (request.headers.get("Accept") ?? "").includes("application/json");
  const reply = (outcome: Outcome) => respond(outcome, wantsJson);

  if (!sameOrigin(request)) return reply("forbidden");
  if (Number(request.headers.get("Content-Length") ?? 0) > MAX_BODY_BYTES) return reply("too_large");

  const fields = await readFields(request, type);
  if (!fields) return reply("invalid_email");
  // Bots fill every field; people never see this one. Answer as if it worked and store nothing.
  if (fields.company) return reply("joined");

  const email = fields.email.trim().toLowerCase();
  if (email.length > 254 || !EMAIL.test(email)) return reply("invalid_email");

  if (await overLimit(env, request.headers.get("CF-Connecting-IP"))) return reply("rate_limited");

  // A repeat sign-up gets the same answer, so the form can't be used to test who is on the list.
  await env.WAITLIST.prepare(
    "INSERT INTO waitlist (email, source, consent, unsubscribe_token) VALUES (?1, ?2, ?3, ?4) ON CONFLICT(email) DO NOTHING",
  )
    .bind(email, cleanSource(fields.source), CONSENT, crypto.randomUUID())
    .run();

  return reply("joined");
};

export const onRequest: PagesFunction<Env> = async () => methodNotAllowed("POST");

async function readFields(request: Request, type: string): Promise<Fields | null> {
  try {
    if (type.includes("application/json")) {
      const body = (await request.json()) as Record<string, unknown>;
      return { email: str(body.email), source: str(body.source), company: str(body.company) };
    }
    if (type.includes("application/x-www-form-urlencoded") || type.includes("multipart/form-data")) {
      const form = await request.formData();
      return { email: str(form.get("email")), source: str(form.get("source")), company: str(form.get("company")) };
    }
  } catch {
    return null;
  }
  return null;
}

function str(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function cleanSource(source: string): string {
  const s = source.trim().toLowerCase().slice(0, 40);
  return /^[a-z0-9_-]+$/.test(s) ? s : "site";
}

async function overLimit(env: Env, ip: string | null): Promise<boolean> {
  if (!ip) return false;
  const now = Math.floor(Date.now() / 1000);
  const window = now - (now % WINDOW_SECONDS);
  const ipHash = await sha256Hex(`${env.RATE_SALT ?? "local-dev"}:${ip}`);
  const [, counted] = await env.WAITLIST.batch<{ hits: number }>([
    env.WAITLIST.prepare("DELETE FROM waitlist_rate WHERE window_start < ?1").bind(now - 3600),
    env.WAITLIST.prepare(
      "INSERT INTO waitlist_rate (ip_hash, window_start, hits) VALUES (?1, ?2, 1) ON CONFLICT(ip_hash, window_start) DO UPDATE SET hits = hits + 1 RETURNING hits",
    ).bind(ipHash, window),
  ]);
  return (counted.results[0]?.hits ?? 0) > MAX_PER_WINDOW;
}

function respond(outcome: Outcome, wantsJson: boolean): Response {
  if (wantsJson) {
    if (outcome === "joined") return json(200, { ok: true });
    const status = { invalid_email: 400, rate_limited: 429, forbidden: 403, too_large: 413 }[outcome];
    return json(status, { ok: false, error: outcome }, outcome === "rate_limited" ? { "Retry-After": String(WINDOW_SECONDS) } : {});
  }
  if (outcome === "joined") return redirect("/?joined=1#joined");
  // The page is static, so each outcome has its own anchored message that CSS :target reveals.
  return redirect(`/?joined=0&error=${outcome}#join-error-${outcome}`);
}
