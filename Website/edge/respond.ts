// Pages `_headers` rules do not apply to Functions responses, so every function sets its own.
const BASE_HEADERS: Record<string, string> = {
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
};

export function json(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...BASE_HEADERS,
      "Content-Type": "application/json; charset=utf-8",
      "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
      ...extra,
    },
  });
}

export function redirect(location: string): Response {
  return new Response(null, { status: 303, headers: { ...BASE_HEADERS, Location: location } });
}

export function page(status: number, title: string, body: string): Response {
  const doc = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>${title} · Farside</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#050505;color:#e8e6e1;font:17px/1.5 -apple-system,system-ui,sans-serif}main{max-width:32rem;padding:24px}h1{font-size:28px;margin:0 0 12px}a{color:#ff5b1f}button{font:inherit;padding:12px 20px;border:0;border-radius:10px;background:#ff5b1f;color:#050505;cursor:pointer}</style>
</head><body><main>${body}</main></body></html>`;
  return new Response(doc, {
    status,
    headers: {
      ...BASE_HEADERS,
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy":
        "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    },
  });
}

export function methodNotAllowed(allow: string): Response {
  return json(405, { ok: false, error: "method_not_allowed" }, { Allow: allow });
}

/** Rejects cross-site posts. Browsers send Origin on form and fetch POSTs; its absence (curl, old clients) is allowed. */
export function sameOrigin(request: Request): boolean {
  const origin = request.headers.get("Origin");
  if (!origin || origin === "null") return origin === null;
  try {
    return new URL(origin).host === new URL(request.url).host;
  } catch {
    return false;
  }
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
