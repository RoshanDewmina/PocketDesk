import { base64Decode, base64UrlEncode, utf8 } from "../util";

// App Store Server API (developer.apple.com/documentation/appstoreserverapi, read 29 Sep 2026):
// ES256 JWT with kid/iss/iat/exp (≤ 60 min)/aud "appstoreconnect-v1"/bid.
export const APPLE_API_BASE = {
  Production: "https://api.storekit.apple.com",
  Sandbox: "https://api.storekit-sandbox.apple.com",
} as const;

export type AppleApiConfig = {
  issuerId: string;
  keyId: string;
  privateKeyPem: string;
  bundleId: string;
  environment: keyof typeof APPLE_API_BASE;
  fetch?: typeof globalThis.fetch;
};

export function appleApiConfigFromEnv(env: Env, environment: keyof typeof APPLE_API_BASE): AppleApiConfig | undefined {
  if (!env.APPLE_IAP_ISSUER_ID || !env.APPLE_IAP_KEY_ID || !env.APPLE_IAP_PRIVATE_KEY) return undefined;
  return {
    issuerId: env.APPLE_IAP_ISSUER_ID,
    keyId: env.APPLE_IAP_KEY_ID,
    privateKeyPem: env.APPLE_IAP_PRIVATE_KEY,
    bundleId: env.APP_BUNDLE_ID,
    environment,
  };
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----BEGIN [A-Z ]+-----/g, "").replace(/-----END [A-Z ]+-----/g, "").replace(/\s+/g, "");
  return crypto.subtle.importKey("pkcs8", base64Decode(body) as BufferSource, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

export async function signAppleJwt(config: AppleApiConfig, nowMs: number): Promise<string> {
  const iat = Math.floor(nowMs / 1000);
  const header = base64UrlEncode(utf8(JSON.stringify({ alg: "ES256", kid: config.keyId, typ: "JWT" })));
  const claims = base64UrlEncode(utf8(JSON.stringify({ iss: config.issuerId, iat, exp: iat + 20 * 60, aud: "appstoreconnect-v1", bid: config.bundleId })));
  const key = await importPrivateKey(config.privateKeyPem);
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8(`${header}.${claims}`) as BufferSource));
  return `${header}.${claims}.${base64UrlEncode(signature)}`;
}

async function call(config: AppleApiConfig, method: "GET" | "POST", path: string, nowMs: number, requestBody?: unknown, maxBytes = 64 * 1024): Promise<{ status: number; body: unknown }> {
  const fetcher = config.fetch ?? globalThis.fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 8000);
  try {
    const response = await fetcher(`${APPLE_API_BASE[config.environment]}${path}`, {
      method,
      headers: { authorization: `Bearer ${await signAppleJwt(config, nowMs)}`, accept: "application/json", ...(requestBody ? { "content-type": "application/json" } : {}) },
      ...(requestBody ? { body: JSON.stringify(requestBody) } : {}),
      signal: controller.signal,
    });
    const reader = response.body?.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    if (reader) {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > maxBytes) { await reader.cancel(); throw new Error("Apple response exceeds limit"); }
        chunks.push(value);
      }
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const text = new TextDecoder().decode(bytes);
    let body: unknown = undefined;
    if (text.length > 0 && text.length <= maxBytes) {
      try { body = JSON.parse(text); } catch { body = undefined; }
    }
    return { status: response.status, body };
  } finally {
    clearTimeout(timer);
  }
}

export const requestTestNotification = (config: AppleApiConfig, nowMs: number) =>
  call(config, "POST", "/inApps/v1/notifications/test", nowMs);

export const getTestNotificationStatus = (config: AppleApiConfig, token: string, nowMs: number) =>
  call(config, "GET", `/inApps/v1/notifications/test/${encodeURIComponent(token)}`, nowMs);

/** The caller verifies the returned JWS and exact identity; this transport response grants nothing. */
export const getTransactionInfo = (config: AppleApiConfig, transactionId: string, nowMs: number) => {
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(transactionId)) throw new Error("transaction identifier invalid");
  return call(config, "GET", `/inApps/v1/transactions/${encodeURIComponent(transactionId)}`, nowMs);
};

/** Transport metadata is untrusted; callers verify every returned notification/transaction/renewal JWS.
 * Apple official Node client and NotificationHistoryRequest checked 2 Oct 2026. */
export function getNotificationHistory(config: AppleApiConfig, window: { startDate: number; endDate: number; paginationToken?: string | null }, nowMs: number) {
  if (!Number.isSafeInteger(window.startDate) || !Number.isSafeInteger(window.endDate) || window.startDate >= window.endDate ||
      (window.paginationToken != null && (window.paginationToken.length === 0 || window.paginationToken.length > 4096))) throw new Error("history window invalid");
  const query = window.paginationToken ? `?paginationToken=${encodeURIComponent(window.paginationToken)}` : "";
  return call(config, "POST", `/inApps/v1/notifications/history${query}`, nowMs, { startDate: window.startDate, endDate: window.endDate }, 2 * 1024 * 1024);
}

export function getAllSubscriptionStatuses(config: AppleApiConfig, transactionId: string, nowMs: number) {
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(transactionId)) throw new Error("transaction identifier invalid");
  return call(config, "GET", `/inApps/v1/subscriptions/${encodeURIComponent(transactionId)}`, nowMs, undefined, 512 * 1024);
}
