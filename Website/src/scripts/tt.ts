// The site's CSP enforces Trusted Types and allows exactly one named policy, "farside", used for one thing:
// starting the reach background's worker from its own bundle URL (scripts/build.ts compiles that URL in).

declare const __REACH_WORKER__: string;

type Policy = { createScriptURL(u: string): unknown };
type Factory = { createPolicy(n: string, p: { createScriptURL(u: string): string }): Policy };

let policy: Policy | null | undefined;

function get(): Policy | null {
  if (policy !== undefined) return policy;
  const tt = (window as unknown as { trustedTypes?: Factory }).trustedTypes;
  policy = tt
    ? tt.createPolicy("farside", {
        createScriptURL: (u) => {
          if (u === __REACH_WORKER__) return u;
          throw new TypeError("blocked script URL");
        },
      })
    : null;
  return policy;
}

export const reachWorkerURL = (): string => (get()?.createScriptURL(__REACH_WORKER__) ?? __REACH_WORKER__) as string;
