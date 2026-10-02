import { logError } from "./log";

type Limiter = { limit(options: { key: string }): Promise<{ success: boolean }> };
export type RateDecision = "allowed" | "denied" | "unavailable";
type StrictRateEnv = { STRICT_RATE_LIMITS?: string };

/** Only the explicit rollback value restores legacy permissive public admission. */
export const strictRateLimitsEnabled = (env: StrictRateEnv): boolean => env.STRICT_RATE_LIMITS !== "0";

/** Distinguishes exhausted quota from a missing or failing security dependency. */
export async function strictRateDecision(limiter: Limiter | undefined, key: string, name: string): Promise<RateDecision> {
  if (!limiter) return "unavailable";
  try {
    return (await limiter.limit({ key })).success ? "allowed" : "denied";
  } catch (error) {
    logError("ratelimit_binding_failed", error, { limiter: name });
    return "unavailable";
  }
}

/** Public endpoints retain their original fail-open behavior only during explicit rollback. */
export async function publicRateDecision(limiter: Limiter | undefined, key: string, name: string, env: StrictRateEnv): Promise<RateDecision> {
  if (!strictRateLimitsEnabled(env)) return await allow(limiter, key, name) ? "allowed" : "denied";
  return strictRateDecision(limiter, key, name);
}

/** Cloudflare rate-limit binding check. Counters are per Cloudflare location. A missing or failing binding allows the request and logs it. */
export async function allow(limiter: Limiter | undefined, key: string, name: string): Promise<boolean> {
  if (!limiter) return true;
  try {
    return (await limiter.limit({ key })).success;
  } catch (error) {
    logError("ratelimit_binding_failed", error, { limiter: name });
    return true;
  }
}

/** Security-sensitive admission, issuance and writes fail closed when their quota binding is absent or unavailable. */
export async function allowStrict(limiter: Limiter | undefined, key: string, name: string): Promise<boolean> {
  return await strictRateDecision(limiter, key, name) === "allowed";
}

/** Rate-limit key for a client address: IPv4 as is, IPv6 by its /64 so one host cannot rotate through its prefix. */
export function addressKey(ip: string | null | undefined): string {
  if (!ip) return "unknown";
  if (!ip.includes(":")) return ip;
  const groups = ip.split("::");
  const head = (groups[0] ?? "").split(":").filter(Boolean);
  while (head.length < 4) head.push("0");
  return `${head.slice(0, 4).join(":")}::/64`;
}

/** Fixed-window counter kept in memory (per socket or per room). Resets when the holder is recreated. */
export class WindowCounter {
  private count = 0;
  private windowStart = 0;

  constructor(private readonly limit: number, private readonly windowMs: number) {}

  hit(now: number, amount = 1): boolean {
    if (now - this.windowStart >= this.windowMs) {
      this.windowStart = now;
      this.count = 0;
    }
    this.count += amount;
    return this.count <= this.limit;
  }
}

/** Rejects a promise that takes longer than `ms`; used to bound storage lookups inside the room object. */
export function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} timed out`)), ms);
    promise.then(value => { clearTimeout(timer); resolve(value); }, error => { clearTimeout(timer); reject(error); });
  });
}
