import type { IceServer } from "./protocol";

/**
 * `not_found` is not success: right after `generate-ice-servers` Cloudflare's revoke endpoint answers 404
 * ("cannot find specified username") until the credential has propagated, and a retry moments later succeeds
 * (observed live on the Bun relay, 29 Sep 2026). The caller decides what a 404 means from the credential's age.
 */
export type RevokeStatus = "confirmed" | "not_found" | "failed";
export type RevokeOutcome = { username: string; status: RevokeStatus };

export type TurnProvider = {
  readonly ttlSeconds: number;
  issue(): Promise<IceServer[]>;
  /** One outcome per distinct username; never throws for a single username's failure. */
  revoke(usernames: string[]): Promise<RevokeOutcome[]>;
};

const allowedIceURL = /^(?:stun|stuns|turn|turns):[^\s]{1,500}$/;
const maxProviderResponseBytes = 64 * 1024;

async function readBoundedJSON(response: Response): Promise<unknown> {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxProviderResponseBytes) throw new Error("TURN credential response too large");
  if (!response.body) throw new Error("empty TURN credential response");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > maxProviderResponseBytes) {
      await reader.cancel();
      throw new Error("TURN credential response too large");
    }
    chunks.push(value);
  }
  const body = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder().decode(body));
}

export function validateIceServers(value: unknown): IceServer[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 8) throw new Error("invalid TURN credential response");
  let hasTurn = false;
  const servers = value.map((item): IceServer => {
    if (!item || typeof item !== "object" || Array.isArray(item)) throw new Error("invalid TURN credential response");
    const candidate = item as Record<string, unknown>;
    const rawURLs = typeof candidate.urls === "string" ? [candidate.urls] : candidate.urls;
    if (!Array.isArray(rawURLs) || rawURLs.length === 0 || rawURLs.length > 8 ||
        !rawURLs.every(url => typeof url === "string" && allowedIceURL.test(url))) {
      throw new Error("invalid TURN credential response");
    }
    const urls = rawURLs as string[];
    const needsCredential = urls.some(url => url.startsWith("turn:") || url.startsWith("turns:"));
    hasTurn ||= needsCredential;
    if (needsCredential &&
        (typeof candidate.username !== "string" || candidate.username.length < 1 || candidate.username.length > 1024 ||
         typeof candidate.credential !== "string" || candidate.credential.length < 1 || candidate.credential.length > 1024)) {
      throw new Error("invalid TURN credential response");
    }
    return {
      urls,
      ...(typeof candidate.username === "string" ? { username: candidate.username } : {}),
      ...(typeof candidate.credential === "string" ? { credential: candidate.credential } : {}),
    };
  });
  if (!hasTurn) throw new Error("TURN credential response contained no relay");
  return servers;
}

export function createCloudflareTurnProvider(config: {
  keyId: string;
  apiToken: string;
  ttlSeconds: number;
  timeoutMs: number;
  fetch?: typeof globalThis.fetch;
  endpoint?: string;
}): TurnProvider {
  if (!/^[A-Za-z0-9]{32}$/.test(config.keyId)) throw new Error("invalid Cloudflare TURN key ID");
  if (config.apiToken.length !== 64) throw new Error("invalid Cloudflare TURN API token");
  if (!Number.isSafeInteger(config.ttlSeconds) || config.ttlSeconds < 60 || config.ttlSeconds > 86_400) throw new Error("invalid TURN credential TTL");
  if (!Number.isSafeInteger(config.timeoutMs) || config.timeoutMs < 1 || config.timeoutMs > 10_000) throw new Error("invalid TURN provider timeout");
  // Resolved per call so a test that replaces the global fetch after this object was built still applies.
  const fetcher = (): typeof globalThis.fetch => config.fetch ?? globalThis.fetch;
  const base = config.endpoint ?? "https://rtc.live.cloudflare.com";
  const keyPath = `/v1/turn/keys/${encodeURIComponent(config.keyId)}`;

  return {
    ttlSeconds: config.ttlSeconds,
    async issue() {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), config.timeoutMs);
      try {
        const response = await fetcher()(new URL(`${keyPath}/credentials/generate-ice-servers`, base), {
          method: "POST",
          headers: { authorization: `Bearer ${config.apiToken}`, "content-type": "application/json" },
          body: JSON.stringify({ ttl: config.ttlSeconds }),
          signal: controller.signal,
        });
        if (response.status !== 201) throw new Error("TURN credential provider rejected request");
        const body = (await readBoundedJSON(response)) as { iceServers?: unknown };
        return validateIceServers(body?.iceServers);
      } catch {
        throw new Error("TURN credential provider unavailable");
      } finally {
        clearTimeout(timer);
      }
    },
    async revoke(usernames) {
      return revokeEach(usernames, async username => {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), config.timeoutMs);
        try {
          const response = await fetcher()(new URL(`${keyPath}/credentials/${encodeURIComponent(username)}/revoke`, base), {
            method: "POST",
            headers: { authorization: `Bearer ${config.apiToken}` },
            signal: controller.signal,
          });
          if (response.status === 204) return "confirmed";
          if (response.status === 404) return "not_found";
          return "failed";
        } finally {
          clearTimeout(timer);
        }
      });
    },
  };
}

/** Attempts every revocation independently; a thrown error or timeout counts as `failed` for that username only. */
export async function revokeEach(usernames: string[], revokeOne: (username: string) => Promise<RevokeStatus>): Promise<RevokeOutcome[]> {
  const unique = [...new Set(usernames)];
  const results = await Promise.allSettled(unique.map(username => revokeOne(username)));
  return unique.map((username, index) => {
    const result = results[index]!;
    return { username, status: result.status === "fulfilled" ? result.value : "failed" };
  });
}

export function turnProviderFromEnv(env: Env, fetcher?: typeof globalThis.fetch): TurnProvider | undefined {
  if (!env.CLOUDFLARE_TURN_KEY_ID || !env.CLOUDFLARE_TURN_KEY_API_TOKEN) return undefined;
  return createCloudflareTurnProvider({
    keyId: env.CLOUDFLARE_TURN_KEY_ID,
    apiToken: env.CLOUDFLARE_TURN_KEY_API_TOKEN,
    ttlSeconds: Number(env.TURN_CREDENTIAL_TTL_SECONDS || 3600),
    timeoutMs: 3000,
    ...(fetcher ? { fetch: fetcher } : {}),
  });
}
