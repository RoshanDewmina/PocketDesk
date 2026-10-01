// The site's CSP enforces Trusted Types and allows exactly one named policy, "farside". The "See it" demo
// (src/hero-a2/a2.js) writes two fixed, script-built HTML strings through it; nothing else needs it.

type Policy = { createHTML(s: string): unknown };
type Factory = { createPolicy(n: string, p: { createHTML(s: string): string }): Policy };

let policy: Policy | null | undefined;

function get(): Policy | null {
  if (policy !== undefined) return policy;
  const tt = (window as unknown as { trustedTypes?: Factory }).trustedTypes;
  policy = tt ? tt.createPolicy("farside", { createHTML: (s) => s }) : null;
  return policy;
}

export const trustedHTML = (s: string): string => (get()?.createHTML(s) ?? s) as string;
