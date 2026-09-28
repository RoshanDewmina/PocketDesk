import { lookup } from 'node:dns/promises';
import { request as httpsRequest } from 'node:https';
import { isIPv4, isIPv6 } from 'node:net';
import { Readable } from 'node:stream';

const MAX_CIMD_BYTES = 16 * 1024;
const FETCH_TIMEOUT_MS = 3_000;
const CACHE_TTL_MS = 30_000;
const MAX_CACHE_ENTRIES = 256;

export type ClientMetadataDocument = {
  client_id: string;
  redirect_uris: string[];
  client_name?: string;
  token_endpoint_auth_method?: string;
};

function ipv4Blocked(octets: number[]) {
  const [a, b] = octets;
  if (a === 10 || a === 127 || a === 0) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT
  if (a === 192 && b === 0) return true;
  if (a === 192 && b === 0 && octets[2] === 2) return true;
  if (a === 198 && (b === 18 || b === 19 || b === 51)) return true;
  if (a === 203 && b === 0 && octets[2] === 113) return true;
  if (a >= 224) return true;
  return false;
}

function isPrivateAddress(address: string, family: number): boolean {
  if (family === 4 || isIPv4(address)) {
    const octets = address.split('.').map(Number);
    return octets.length === 4 && octets.every(n => Number.isInteger(n) && n >= 0 && n <= 255) && ipv4Blocked(octets);
  }
  if (family === 6 || isIPv6(address)) {
    const normalized = address.toLowerCase();
    if (normalized === '::1' || normalized === '::') return true;
    if (normalized.startsWith('fe80:') || normalized.startsWith('fec0:')) return true; // link-local
    if (/^f[cd][0-9a-f]{2}:/.test(normalized)) return true; // unique local fc00::/7
    if (normalized.startsWith('ff')) return true; // multicast
    if (normalized.startsWith('2001:db8:')) return true; // documentation
    if (normalized.startsWith('::ffff:')) return isPrivateAddress(normalized.slice(7), 4);
    return false;
  }
  return true; // unknown family: fail closed
}

type PublicAddress = { address: string; family: number };

async function publicHttpsAddresses(url: URL): Promise<PublicAddress[]> {
  if (url.protocol !== 'https:') throw new Error('cimd_https_required');
  if (url.username || url.password) throw new Error('cimd_invalid_url');
  const hostname = url.hostname.replace(/^\[|\]$/g, '');
  if (hostname === 'localhost') throw new Error('cimd_private_address');
  let records: Array<{ address: string; family: number }>;
  try {
    records = await lookup(hostname, { all: true, verbatim: true });
  } catch {
    throw new Error('cimd_dns_failed');
  }
  if (records.length === 0 || records.some(record => isPrivateAddress(record.address, record.family))) {
    throw new Error('cimd_private_address');
  }
  return records;
}

function fetchPinnedHttps(url: URL, endpoint: PublicAddress, signal: AbortSignal): Promise<Response> {
  return new Promise((resolve, reject) => {
    const req = httpsRequest(url, {
      method: 'GET',
      headers: { Accept: 'application/json' },
      signal,
      lookup: (_hostname, _options, callback) => callback(null, endpoint.address, endpoint.family),
      servername: url.hostname,
    }, response => {
      const headers = new Headers();
      for (const [name, value] of Object.entries(response.headers)) {
        if (Array.isArray(value)) for (const item of value) headers.append(name, item);
        else if (value !== undefined) headers.set(name, value);
      }
      resolve(new Response(Readable.toWeb(response) as ReadableStream<Uint8Array>, {
        status: response.statusCode ?? 502,
        statusText: response.statusMessage,
        headers,
      }));
    });
    req.once('error', reject);
    req.end();
  });
}

async function abortable<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) throw new Error('cimd_timeout');
  return await new Promise<T>((resolve, reject) => {
    const abort = () => reject(new Error('cimd_timeout'));
    signal.addEventListener('abort', abort, { once: true });
    promise.then(
      value => { signal.removeEventListener('abort', abort); resolve(value); },
      error => { signal.removeEventListener('abort', abort); reject(error); },
    );
  });
}

type CacheEntry = { document: ClientMetadataDocument; expiresAt: number };
const cache = new Map<string, CacheEntry>();

function cacheGet(url: string, now: number): ClientMetadataDocument | undefined {
  const entry = cache.get(url);
  if (!entry || entry.expiresAt <= now) { cache.delete(url); return undefined; }
  return entry.document;
}

function cacheSet(url: string, document: ClientMetadataDocument, now: number) {
  if (cache.size >= MAX_CACHE_ENTRIES) cache.delete(cache.keys().next().value as string);
  cache.set(url, { document, expiresAt: now + CACHE_TTL_MS });
}

export type CimdFetcher = (url: string) => Promise<ClientMetadataDocument>;

/**
 * Fetches a Client ID Metadata Document per draft-ietf-oauth-client-id-metadata-document-00.
 * The client_id itself IS the HTTPS URL of the document (no separate lookup key).
 * Hardened: HTTPS only, resolved-address SSRF checks, no redirects, bounded size/time, brief cache.
 */
export async function fetchClientMetadataDocument(
  clientId: string,
  now: () => number = Date.now,
  fetchImpl: typeof fetch = fetch,
): Promise<ClientMetadataDocument> {
  const cached = cacheGet(clientId, now());
  if (cached) return cached;

  let url: URL;
  try { url = new URL(clientId); } catch { throw new Error('cimd_invalid_url'); }
  const addresses = await publicHttpsAddresses(url);

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  let response: Response;
  let text: string;
  try {
    response = fetchImpl === globalThis.fetch
      ? await fetchPinnedHttps(url, addresses[0]!, controller.signal)
      : await fetchImpl(url, { redirect: 'manual', signal: controller.signal, headers: { Accept: 'application/json' } });
    if (response.status >= 300 && response.status < 400) throw new Error('cimd_redirect_rejected');
    if (!response.ok) throw new Error('cimd_fetch_failed');
    const declaredLength = Number(response.headers.get('content-length') ?? '0');
    if (Number.isFinite(declaredLength) && declaredLength > MAX_CIMD_BYTES) throw new Error('cimd_too_large');

    const reader = response.body?.getReader();
    if (!reader) {
      text = await abortable(response.text(), controller.signal);
      if (Buffer.byteLength(text) > MAX_CIMD_BYTES) throw new Error('cimd_too_large');
    } else {
      const chunks: Uint8Array[] = [];
      let total = 0;
      while (true) {
        const { done, value } = await abortable(reader.read(), controller.signal);
        if (done) break;
        if (!value) continue;
        total += value.byteLength;
        if (total > MAX_CIMD_BYTES) { await reader.cancel().catch(() => {}); throw new Error('cimd_too_large'); }
        chunks.push(value);
      }
      text = Buffer.concat(chunks.map(c => Buffer.from(c))).toString('utf8');
    }
  } catch (error) {
    if (error instanceof Error && error.message.startsWith('cimd_')) throw error;
    throw new Error('cimd_fetch_failed');
  } finally {
    clearTimeout(timer);
  }

  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { throw new Error('cimd_invalid_json'); }
  if (typeof parsed !== 'object' || parsed === null) throw new Error('cimd_invalid_json');
  const document = parsed as Record<string, unknown>;
  if (document.client_id !== clientId) throw new Error('cimd_client_id_mismatch');
  if (!Array.isArray(document.redirect_uris) || document.redirect_uris.length === 0 ||
      !document.redirect_uris.every(uri => typeof uri === 'string' && uri.length < 2048 && (() => {
        try {
          const redirect = new URL(uri);
          return redirect.protocol === 'https:' && !redirect.username && !redirect.password && !redirect.hash;
        } catch { return false; }
      })())) {
    throw new Error('cimd_invalid_redirect_uris');
  }
  const result: ClientMetadataDocument = {
    client_id: clientId,
    redirect_uris: document.redirect_uris as string[],
    client_name: typeof document.client_name === 'string' ? document.client_name.slice(0, 200) : undefined,
    token_endpoint_auth_method: typeof document.token_endpoint_auth_method === 'string' ? document.token_endpoint_auth_method : undefined,
  };
  cacheSet(clientId, result, now());
  return result;
}

export function isCimdClientId(clientId: string): boolean {
  try { return new URL(clientId).protocol === 'https:'; } catch { return false; }
}
