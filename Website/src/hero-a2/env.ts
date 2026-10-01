// The helpers the hero lab defines around its demos (design/hero-lab/src/index.html), which a2.js expects in
// scope. Kept as close to the lab as possible so a re-sync of a2.js (scripts/sync-hero-a2.ts) stays a swap.

type Token = { dead: boolean };

export const RM = matchMedia("(prefers-reduced-motion: reduce)").matches;
export const clamp = (v: number, a: number, b: number) => Math.max(a, Math.min(b, v));
export const ease = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

/** The element holding the demo (#stage). Set by mount() before initA2() runs; a2.js reads it as a live binding. */
export let stage: HTMLElement = null as unknown as HTMLElement;

// Animation clock that pauses while the demo is off screen or the tab is hidden.
export let paused = false;
export const waiters: (() => void)[] = [];
const setPaused = (p: boolean) => {
  paused = p;
  if (!p) waiters.splice(0).forEach((f) => f());
};

export function tween(ms: number, fn: (t: number) => void, tok: Token): Promise<boolean> {
  return new Promise((res) => {
    let el = 0;
    let last: number | null = null;
    const step = (now: number) => {
      if (tok.dead) return res(false);
      if (paused) {
        last = null;
        waiters.push(() => requestAnimationFrame(step));
        return;
      }
      if (last !== null) el += Math.min(50, now - last);
      last = now;
      const t = Math.min(1, el / ms);
      fn(t);
      if (t < 1) requestAnimationFrame(step);
      else res(true);
    };
    requestAnimationFrame(step);
  });
}
export const wait = (ms: number, tok: Token) => tween(ms, () => {}, tok);

// The site's CSP requires Trusted Types. a2.js writes two fixed, script-built HTML strings (terminal lines and
// the status line); they go through the site's one named policy (src/scripts/tt.ts). No user input reaches them.
export { trustedHTML } from "../scripts/tt";

export function mount(el: HTMLElement) {
  stage = el;
  new IntersectionObserver((es) => setPaused(!es[0]!.isIntersecting || document.hidden)).observe(el);
  document.addEventListener("visibilitychange", () => setPaused(document.hidden));
}
