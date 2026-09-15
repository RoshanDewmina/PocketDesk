import { createHash, randomBytes } from 'node:crypto';

export const MAX_MCP_HTTP_BODY_BYTES = 256 * 1024;

export const mcpSecurityHeaders: Record<string, string> = {
  'Cache-Control': 'no-store',
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'Cross-Origin-Opener-Policy': 'same-origin',
};

class BodyTooLarge extends Error {}
export { BodyTooLarge };

export async function readBodyCapped(request: Request, cap: number): Promise<Uint8Array> {
  if (!request.body) return new Uint8Array(0);
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value || value.byteLength === 0) continue;
    total += value.byteLength;
    if (total > cap) {
      try { await reader.cancel(); } catch { /* connection may already be gone */ }
      throw new BodyTooLarge();
    }
    chunks.push(value);
  }
  const combined = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { combined.set(chunk, offset); offset += chunk.byteLength; }
  return combined;
}

export function jsonResponse(body: unknown, init: ResponseInit = {}) {
  return new Response(JSON.stringify(body), {
    ...init,
    headers: { ...mcpSecurityHeaders, 'Content-Type': 'application/json', ...(init.headers as Record<string, string> ?? {}) },
  });
}

export function oauthError(status: number, error: string, description?: string, extraHeaders?: Record<string, string>) {
  return jsonResponse({ error, ...(description ? { error_description: description } : {}) }, { status, headers: extraHeaders });
}

export function base64url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString('base64url');
}

export function randomToken(bytes = 32): string {
  return base64url(randomBytes(bytes));
}

export function sha256Base64Url(value: string): string {
  return createHash('sha256').update(value).digest('base64url');
}

/** RFC 7636 PKCE S256 verification. `plain` and missing verifiers are always rejected by callers. */
export function verifyPkceS256(codeVerifier: string, codeChallenge: string): boolean {
  if (!/^[A-Za-z0-9._~-]{43,128}$/.test(codeVerifier)) return false;
  return sha256Base64Url(codeVerifier) === codeChallenge;
}

export function isValidCodeChallenge(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{43,128}$/.test(value);
}

export function randomDigits(length: number): string {
  const digits = '0123456789';
  const bytes = randomBytes(length);
  let out = '';
  for (let i = 0; i < length; i++) out += digits[bytes[i] % 10];
  return out;
}

const CONFIRMATION_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no ambiguous chars
export function randomConfirmationCode(): string {
  const bytes = randomBytes(6);
  let out = '';
  for (let i = 0; i < 6; i++) out += CONFIRMATION_ALPHABET[bytes[i] % CONFIRMATION_ALPHABET.length];
  return out;
}

/** Fixed-window per-minute cap, used to bound Dynamic Client Registration. */
export class PerMinuteLimiter {
  private windowStart = 0;
  private count = 0;
  constructor(private readonly limit: number, private readonly now: () => number = Date.now) {}

  tryConsume(): boolean {
    const current = this.now();
    if (current - this.windowStart >= 60_000) { this.windowStart = current; this.count = 0; }
    if (this.count >= this.limit) return false;
    this.count += 1;
    return true;
  }
}
