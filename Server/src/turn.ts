import { createHmac, randomUUID } from 'node:crypto';

export type PeerRole = 'host' | 'client';

export type IceServer = {
  urls: string[];
  username?: string;
  credential?: string;
};

export type TurnCredentialProvider = {
  readonly kind: 'coturn' | 'cloudflare';
  /** How long each issued credential stays valid. The signaling service schedules refreshes from it. */
  readonly ttlSeconds?: number;
  issue(context: { room: string; role: PeerRole }): Promise<IceServer[]>;
  revoke?(servers: IceServer[]): Promise<void>;
};

const allowedIceURL = /^(?:stun|stuns|turn|turns):[^\s]{1,500}$/;
const maxProviderResponseBytes = 64 * 1024;

async function readBoundedJSON(response: Response): Promise<unknown> {
  const declaredLength = Number(response.headers.get('content-length'));
  if (Number.isFinite(declaredLength) && declaredLength > maxProviderResponseBytes) {
    throw new Error('TURN credential response too large');
  }
  if (!response.body) throw new Error('empty TURN credential response');
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > maxProviderResponseBytes) {
      await reader.cancel();
      throw new Error('TURN credential response too large');
    }
    chunks.push(value);
  }
  const body = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder().decode(body));
}

function validateIceServers(value: unknown): IceServer[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 8) {
    throw new Error('invalid TURN credential response');
  }

  let hasTurn = false;
  const servers = value.map((item): IceServer => {
    if (!item || typeof item !== 'object' || Array.isArray(item)) throw new Error('invalid TURN credential response');
    const candidate = item as Record<string, unknown>;
    const rawURLs = typeof candidate.urls === 'string' ? [candidate.urls] : candidate.urls;
    if (!Array.isArray(rawURLs) || rawURLs.length === 0 || rawURLs.length > 8 ||
        !rawURLs.every(url => typeof url === 'string' && allowedIceURL.test(url))) {
      throw new Error('invalid TURN credential response');
    }
    const urls = rawURLs as string[];
    const needsCredential = urls.some(url => url.startsWith('turn:') || url.startsWith('turns:'));
    hasTurn ||= needsCredential;
    if (needsCredential &&
        (typeof candidate.username !== 'string' || candidate.username.length < 1 || candidate.username.length > 1024 ||
         typeof candidate.credential !== 'string' || candidate.credential.length < 1 || candidate.credential.length > 1024)) {
      throw new Error('invalid TURN credential response');
    }
    return {
      urls,
      ...(typeof candidate.username === 'string' ? { username: candidate.username } : {}),
      ...(typeof candidate.credential === 'string' ? { credential: candidate.credential } : {}),
    };
  });

  if (!hasTurn) throw new Error('TURN credential response contained no relay');
  return servers;
}

export function createCoturnProvider(config: {
  urls: string[];
  secret: string;
  ttlSeconds: number;
  now?: () => number;
}): TurnCredentialProvider {
  if (!config.urls.length || config.urls.length > 8 || !config.urls.every(url => /^(?:turn|turns):[^\s]{1,500}$/.test(url))) {
    throw new Error('coturn requires valid TURN_URLS');
  }
  if (config.secret.length < 32) throw new Error('coturn TURN_SECRET must contain at least 32 characters');
  if (!Number.isSafeInteger(config.ttlSeconds) || config.ttlSeconds < 60 || config.ttlSeconds > 86_400) {
    throw new Error('invalid coturn credential TTL');
  }
  const now = config.now ?? Date.now;
  return {
    kind: 'coturn',
    ttlSeconds: config.ttlSeconds,
    async issue() {
      const username = `${Math.floor(now() / 1000) + config.ttlSeconds}:${randomUUID()}`;
      return [{
        urls: [...config.urls],
        username,
        credential: createHmac('sha1', config.secret).update(username).digest('base64'),
      }];
    },
  };
}

export type RevocationRetry = {
  /** Attempts per credential, including the first. */
  attempts: number;
  baseDelayMs: number;
  maxDelayMs: number;
};

export const defaultRevocationRetry: RevocationRetry = { attempts: 4, baseDelayMs: 250, maxDelayMs: 2000 };

/** Exponential backoff with jitter: between half and all of min(max, base * 2^(attempt-1)). */
export function revocationDelayMs(attempt: number, retry: RevocationRetry, random: () => number = Math.random): number {
  const ceiling = Math.min(retry.maxDelayMs, retry.baseDelayMs * 2 ** (attempt - 1));
  return Math.round(ceiling / 2 + (ceiling / 2) * Math.min(1, Math.max(0, random())));
}

const maxLoggedBodyBytes = 512;

async function readLogBody(response: Response, secrets: string[]): Promise<string> {
  let text = '';
  try {
    const reader = response.body?.getReader();
    if (reader) {
      const chunks: Uint8Array[] = [];
      let length = 0;
      while (length < maxLoggedBodyBytes) {
        const { value, done } = await reader.read();
        if (done) break;
        chunks.push(value);
        length += value.byteLength;
      }
      await reader.cancel().catch(() => {});
      const joined = new Uint8Array(length);
      let offset = 0;
      for (const chunk of chunks) { joined.set(chunk, offset); offset += chunk.byteLength; }
      text = new TextDecoder().decode(joined.subarray(0, maxLoggedBodyBytes));
    }
  } catch {
    text = '';
  }
  for (const secret of secrets) if (secret) text = text.split(secret).join('[redacted]');
  text = text.replace(/[^\x20-\x7e]+/g, ' ').replace(/\s+/g, ' ').trim();
  return text.length > 200 ? `${text.slice(0, 200)}…` : text;
}

export function createCloudflareTurnProvider(config: {
  keyId: string;
  apiToken: string;
  ttlSeconds: number;
  timeoutMs: number;
  fetch?: typeof globalThis.fetch;
  endpoint?: string;
  revocationRetry?: RevocationRetry;
  sleep?: (ms: number) => Promise<void>;
  random?: () => number;
  /** One line per event, never containing the API token, key ID or a credential username. */
  log?: (line: string) => void;
}): TurnCredentialProvider {
  if (!/^[A-Za-z0-9]{32}$/.test(config.keyId)) throw new Error('invalid Cloudflare TURN key ID');
  if (config.apiToken.length !== 64) throw new Error('invalid Cloudflare TURN API token');
  if (!Number.isSafeInteger(config.ttlSeconds) || config.ttlSeconds < 60 || config.ttlSeconds > 86_400) {
    throw new Error('invalid Cloudflare credential TTL');
  }
  if (!Number.isSafeInteger(config.timeoutMs) || config.timeoutMs < 1 || config.timeoutMs > 10_000) {
    throw new Error('invalid Cloudflare provider timeout');
  }
  const fetcher = config.fetch ?? globalThis.fetch;
  const base = config.endpoint ?? 'https://rtc.live.cloudflare.com';
  const retry = config.revocationRetry ?? defaultRevocationRetry;
  if (!Number.isSafeInteger(retry.attempts) || retry.attempts < 1 || retry.attempts > 8 ||
      !(retry.baseDelayMs >= 0) || !(retry.maxDelayMs >= retry.baseDelayMs) || retry.maxDelayMs > 30_000) {
    throw new Error('invalid Cloudflare revocation retry policy');
  }
  const sleep = config.sleep ?? ((ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms)));
  const random = config.random ?? Math.random;
  const log = config.log ?? ((line: string) => console.error(line));

  /** One revocation call. Resolves to undefined on success, or a secret-free reason. */
  const attemptRevocation = async (username: string): Promise<string | undefined> => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), config.timeoutMs);
    try {
      const response = await fetcher(new URL(
        `/v1/turn/keys/${encodeURIComponent(config.keyId)}/credentials/${encodeURIComponent(username)}/revoke`,
        base,
      ), {
        method: 'POST',
        headers: { authorization: `Bearer ${config.apiToken}` },
        signal: controller.signal,
      });
      if (response.status === 204) return undefined;
      const body = await readLogBody(response, [config.apiToken, config.keyId, username, encodeURIComponent(username)]);
      return `status ${response.status}${body ? ` body "${body}"` : ''}`;
    } catch (error) {
      return controller.signal.aborted ? `timed out after ${config.timeoutMs} ms` : `request failed (${(error as Error)?.name ?? 'error'})`;
    } finally {
      clearTimeout(timer);
    }
  };

  /** Retries with backoff; true once Cloudflare confirms. Never logs the username. */
  const revokeWithRetry = async (username: string, index: number, count: number): Promise<boolean> => {
    for (let attempt = 1; attempt <= retry.attempts; attempt += 1) {
      const failure = await attemptRevocation(username);
      if (!failure) {
        if (attempt > 1) log(`TURN revocation: credential ${index} of ${count} revoked on attempt ${attempt}`);
        return true;
      }
      log(`TURN revocation: credential ${index} of ${count}, attempt ${attempt} of ${retry.attempts} failed: ${failure}`);
      if (attempt < retry.attempts) await sleep(revocationDelayMs(attempt, retry, random));
    }
    log(`TURN revocation: credential ${index} of ${count} not revoked after ${retry.attempts} attempts; ` +
      `it lapses on its own within ${config.ttlSeconds} s of issue`);
    return false;
  };
  const credentialURL = new URL(`/v1/turn/keys/${encodeURIComponent(config.keyId)}/credentials/generate-ice-servers`, base);

  return {
    kind: 'cloudflare',
    ttlSeconds: config.ttlSeconds,
    async issue() {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), config.timeoutMs);
      try {
        const response = await fetcher(credentialURL, {
          method: 'POST',
          headers: {
            authorization: `Bearer ${config.apiToken}`,
            'content-type': 'application/json',
          },
          body: JSON.stringify({ ttl: config.ttlSeconds }),
          signal: controller.signal,
        });
        if (response.status !== 201) throw new Error('TURN credential provider rejected request');
        const body = await readBoundedJSON(response) as { iceServers?: unknown };
        return validateIceServers(body?.iceServers);
      } catch {
        throw new Error('TURN credential provider unavailable');
      } finally {
        clearTimeout(timer);
      }
    },
    // Every credential gets its own attempts: one that keeps failing never stops the others from
    // being revoked, and the call still rejects so the caller counts it.
    async revoke(servers) {
      const usernames = [...new Set(servers.flatMap(server => server.username ? [server.username] : []))];
      let failed = 0;
      for (const [index, username] of usernames.entries()) {
        if (!(await revokeWithRetry(username, index + 1, usernames.length))) failed += 1;
      }
      if (failed > 0) throw new Error('TURN credential revocation rejected');
    },
  };
}
