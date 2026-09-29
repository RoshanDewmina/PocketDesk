import { logError } from "./log";

type Limiter = { limit(options: { key: string }): Promise<{ success: boolean }> };

/** Cloudflare rate-limit binding check. A missing or failing binding allows the request and logs it. */
export async function allow(limiter: Limiter | undefined, key: string, name: string): Promise<boolean> {
  if (!limiter) return true;
  try {
    return (await limiter.limit({ key })).success;
  } catch (error) {
    logError("ratelimit_binding_failed", error, { limiter: name });
    return true;
  }
}

/** Fixed-window counter kept in memory (per socket or per room). Resets when the holder is recreated. */
export class WindowCounter {
  private count = 0;
  private windowStart = 0;

  constructor(private readonly limit: number, private readonly windowMs: number) {}

  hit(now: number): boolean {
    if (now - this.windowStart >= this.windowMs) {
      this.windowStart = now;
      this.count = 0;
    }
    this.count += 1;
    return this.count <= this.limit;
  }
}
