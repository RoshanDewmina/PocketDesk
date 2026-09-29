// Beta sign-up forms (hero and #beta). Without JavaScript a form posts normally and the waitlist function
// redirects to /?joined=1#joined or /?joined=0&error=<code>#join-error-<code>; the page shows the matching
// note in #beta with :target, no script needed. With JavaScript the form posts JSON in the page and the
// answer appears in its status line. Messages stay on one line so the hero never reflows.

type Code = "joined" | "invalid_email" | "rate_limited" | "forbidden" | "network";

const MESSAGES: Record<Code, string> = {
  joined: "You’re on the list. We’ll email you.",
  invalid_email: "Check the email address and try again.",
  rate_limited: "Too many tries. Wait a few minutes.",
  forbidden: "Blocked. Reload the page and try again.",
  network: "Couldn’t connect. Please try again.",
};

const SOURCE_KEY = "farside:src";
const SOURCE_RE = /^[a-z0-9_-]{1,40}$/;

type Form = { form: HTMLFormElement; say: (code: Code | "", kind?: "ok" | "err" | "busy" | "") => void; joined: () => void };

function wire(form: HTMLFormElement): Form {
  const email = form.querySelector<HTMLInputElement>("input[name=email]")!;
  const source = form.querySelector<HTMLInputElement>("input[name=source]")!;
  const company = form.querySelector<HTMLInputElement>("input[name=company]");
  const button = form.querySelector<HTMLButtonElement>("button[type=submit]")!;
  const status = document.getElementById(form.dataset.status ?? "")!;
  const label = button.textContent;
  // The script checks the address itself and answers inline; without it the browser's own check applies.
  form.noValidate = true;

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
    email.readOnly = true;
    button.disabled = true;
    button.textContent = "Joined";
    say("joined", "ok");
  };
  const failed = (code: string, focus = true) => {
    const known = (code in MESSAGES ? code : "network") as Code;
    say(known, "err");
    if (known === "invalid_email") {
      email.setAttribute("aria-invalid", "true");
      if (focus) email.focus();
    }
  };

  email.addEventListener("input", () => {
    email.removeAttribute("aria-invalid");
    if (status.dataset.kind === "err") say("");
  });

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    if (form.classList.contains("done")) return;
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
      if (!form.classList.contains("done")) {
        button.disabled = false;
        button.textContent = label;
      }
    }
  });
  return { form, say, joined };
}

export function initWaitlist() {
  const forms = [...document.querySelectorAll<HTMLFormElement>("form[data-waitlist]")].map(wire);
  if (!forms.length) return;

  // Back from a plain form post (or a reload after one). The #joined / #join-error-<code> notes already show
  // the result through :target; without such an anchor (an older redirect), the #beta form says it instead.
  const q = new URLSearchParams(location.search);
  if (!q.has("joined")) return;
  const ok = q.get("joined") === "1";
  const note = location.hash ? document.getElementById(decodeURIComponent(location.hash.slice(1))) : null;
  const shown = !!note?.closest(".join-notes");
  const beta = forms.find((f) => f.form.closest("#beta")) ?? forms[0]!;
  if (ok) forms.forEach((f) => f.joined());
  if (shown) forms.forEach((f) => f.say(""));
  else if (!ok) beta.say((q.get("error") as Code) in MESSAGES ? (q.get("error") as Code) : "network", "err");
  history.replaceState(null, "", location.pathname + location.hash);
}
