import { base64UrlDecode, base64UrlEncode, fromUtf8, hmacSha256, isRecord, secureEqualBytes, utf8, HEX64 } from "../util";

export const TOKEN_PREFIX = "fe1";
export const MAX_TOKEN_TTL_MS = 24 * 60 * 60 * 1000;

export type EnvironmentLetter = "P" | "S" | "X";

export type EntitlementTokenPayload = {
  v: 1;
  /** deviceId (64 hex) */
  d: string;
  /** entitlement id (HMAC of originalTransactionId, hex) */
  s: string;
  /** expiry, Unix seconds */
  x: number;
  /** environment: Production / Sandbox / Xcode */
  n: EnvironmentLetter;
};

async function sign(key: string, body: string): Promise<Uint8Array> {
  return hmacSha256(key, `${TOKEN_PREFIX}.${body}`);
}

export async function mintEntitlementToken(key: string, payload: EntitlementTokenPayload): Promise<string> {
  const body = base64UrlEncode(utf8(JSON.stringify(payload)));
  return `${TOKEN_PREFIX}.${body}.${base64UrlEncode(await sign(key, body))}`;
}

export async function verifyEntitlementToken(key: string, token: string, nowMs: number): Promise<EntitlementTokenPayload | undefined> {
  if (typeof token !== "string" || token.length > 512) return undefined;
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] !== TOKEN_PREFIX) return undefined;
  let signature: Uint8Array, payload: unknown;
  try {
    signature = base64UrlDecode(parts[2]!);
    payload = JSON.parse(fromUtf8(base64UrlDecode(parts[1]!)));
  } catch {
    return undefined;
  }
  if (!secureEqualBytes(signature, await sign(key, parts[1]!))) return undefined;
  if (!isRecord(payload) || payload.v !== 1 || typeof payload.d !== "string" || !HEX64.test(payload.d) ||
      typeof payload.s !== "string" || !/^[a-f0-9]{64}$/.test(payload.s) ||
      typeof payload.x !== "number" || !Number.isSafeInteger(payload.x) ||
      (payload.n !== "P" && payload.n !== "S" && payload.n !== "X")) {
    return undefined;
  }
  if (payload.x * 1000 <= nowMs) return undefined;
  return { v: 1, d: payload.d, s: payload.s, x: payload.x, n: payload.n };
}

export const environmentLetter = (environment: string): EnvironmentLetter =>
  environment === "Production" ? "P" : environment === "Sandbox" ? "S" : "X";
