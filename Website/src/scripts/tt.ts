// The site's CSP enforces Trusted Types and allows exactly one named policy, "farside". The home page needs
// it twice (the hero worker's script URL, and the demo's two fixed HTML strings), so it is created once here.

declare const __HERO_WORKER__: string;

type Policy = { createHTML(s: string): unknown; createScriptURL(u: string): unknown };
type Factory = { createPolicy(n: string, p: { createHTML(s: string): string; createScriptURL(u: string): string }): Policy };

let policy: Policy | null | undefined;

function get(): Policy | null {
  if (policy !== undefined) return policy;
  const tt = (window as unknown as { trustedTypes?: Factory }).trustedTypes;
  policy = tt
    ? tt.createPolicy("farside", {
        createHTML: (s) => s,
        createScriptURL: (u) => {
          if (u === __HERO_WORKER__) return u;
          throw new TypeError("blocked script URL");
        },
      })
    : null;
  return policy;
}

export const trustedHTML = (s: string): string => (get()?.createHTML(s) ?? s) as string;
export const trustedScriptURL = (u: string): string => (get()?.createScriptURL(u) ?? u) as string;
