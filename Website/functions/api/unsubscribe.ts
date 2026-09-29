import { page, sameOrigin } from "../../edge/respond";

interface Env {
  WAITLIST: D1Database;
}

// GET only shows a button: email security scanners open links, and a GET that unsubscribed would
// remove people who never clicked. The POST does the work.
export const onRequestGet: PagesFunction<Env> = async ({ request }) => {
  const token = tokenFrom(new URL(request.url).searchParams.get("t"));
  if (!token) return invalid();
  return page(
    200,
    "Unsubscribe",
    `<h1>Leave the Farside list?</h1><p>You won't get beta invites or launch news from us any more.</p>
<form method="post" action="/api/unsubscribe"><input type="hidden" name="t" value="${token}"><button type="submit">Unsubscribe</button></form>`,
  );
};

export const onRequestPost: PagesFunction<Env> = async ({ request, env }) => {
  if (!sameOrigin(request)) return invalid();
  let token: string | null = null;
  try {
    token = tokenFrom((await request.formData()).get("t"));
  } catch {
    token = null;
  }
  if (!token) return invalid();
  await env.WAITLIST.prepare(
    "UPDATE waitlist SET unsubscribed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE unsubscribe_token = ?1 AND unsubscribed_at IS NULL",
  )
    .bind(token)
    .run();
  // Same page whether or not the token matched, so tokens can't be probed.
  return page(200, "Unsubscribed", `<h1>You're off the list.</h1><p>We won't email you again. <a href="/">Back to Farside</a></p>`);
};

function tokenFrom(value: unknown): string | null {
  return typeof value === "string" && /^[0-9a-f-]{36}$/.test(value) ? value : null;
}

function invalid(): Response {
  return page(400, "Link not valid", `<h1>That link didn't work.</h1><p>Email us and we'll take you off the list by hand. <a href="/support#contact">Contact</a></p>`);
}
