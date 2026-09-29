// Beta sign-up form (#beta). Without JavaScript the form posts normally and the waitlist function answers
// with a redirect to /?joined=1#beta or /?joined=0&error=<code>#beta. With JavaScript it posts JSON in the
// page and shows the result in the form's status line; the same query strings are read on load.

type Code = "joined" | "invalid_email" | "rate_limited" | "forbidden" | "network";

const MESSAGES: Record<Code, string> = {
  joined: "You’re on the list. We’ll email you when your beta invite is ready.",
  invalid_email: "That email address doesn’t look right. Check it and try again.",
  rate_limited: "Too many tries from your connection. Please try again in a few minutes.",
  forbidden: "That sign-up was blocked. Reload this page and try again.",
  network: "We couldn’t reach the sign-up service. Please try again in a moment.",
};

const SOURCE_KEY = "farside:src";
const SOURCE_RE = /^[a-z0-9_-]{1,40}$/;

export function initWaitlist() {
  const form = document.querySelector<HTMLFormElement>("form.join");
  if (!form) return;
  const email = form.querySelector<HTMLInputElement>("input[name=email]")!;
  const source = form.querySelector<HTMLInputElement>("input[name=source]")!;
  const company = form.querySelector<HTMLInputElement>("input[name=company]");
  const button = form.querySelector<HTMLButtonElement>("button[type=submit]")!;
  const status = form.querySelector<HTMLElement>(".status")!;

  // The last "Join the beta" tap (on this page or another) names the page the sign-up came from.
  const sourceName = () => {
    try {
      const from = sessionStorage.getItem(SOURCE_KEY);
      if (from && SOURCE_RE.test(from)) return from;
    } catch {
      /* storage blocked */
    }
    return source.value;
  };

  const say = (code: Code | "", kind: "ok" | "err" | "busy" | "" = "") => {
    status.textContent = code ? MESSAGES[code] : kind === "busy" ? "Joining…" : "";
    status.dataset.kind = kind;
  };
  const joined = () => {
    form.classList.add("done");
    say("joined", "ok");
    status.focus({ preventScroll: true });
  };
  const failed = (code: string) => {
    const known = (code in MESSAGES ? code : "network") as Code;
    say(known, "err");
    if (known === "invalid_email") {
      email.setAttribute("aria-invalid", "true");
      email.focus();
    }
  };

  email.addEventListener("input", () => {
    email.removeAttribute("aria-invalid");
    if (status.dataset.kind === "err") say("");
  });

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const value = email.value.trim();
    if (!value || !email.checkValidity()) return failed("invalid_email");
    button.disabled = true;
    say("", "busy");
    try {
      const res = await fetch(form.action, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ email: value, source: sourceName(), company: company?.value ?? "" }),
      });
      let body: { ok?: boolean; error?: string } | null = null;
      try {
        body = await res.json();
      } catch {
        /* not JSON (for example a static preview without the function) */
      }
      if (res.ok && body?.ok) return joined();
      const byStatus: Record<number, Code> = { 400: "invalid_email", 403: "forbidden", 429: "rate_limited" };
      failed(body?.error ?? byStatus[res.status] ?? "network");
    } catch {
      failed("network");
    } finally {
      button.disabled = false;
    }
  });

  // Back from a plain form post (or a reload after one).
  const q = new URLSearchParams(location.search);
  if (q.has("joined")) {
    if (q.get("joined") === "1") joined();
    else failed(q.get("error") ?? "network");
    history.replaceState(null, "", location.pathname + location.hash);
  }
}
