import { base64Decode, base64UrlDecode, fromUtf8, isRecord, utf8 } from "../util";
import { bytesEqual, importVerifyKey, parseCertificate, validAt, verifySignedBy, type ParsedCertificate } from "./x509";

// The checks mirror Apple's app-store-server-library (jws_verification.ts): three certificates,
// Apple's in-app-purchase leaf OID and WWDR intermediate OID, a pinned root, ES256, dates at
// signedDate with 60 s skew. OCSP is not performed (Apple's offline mode); see DESIGN.md §11.
export const APPLE_LEAF_OID = "1.2.840.113635.100.6.11.1";
export const APPLE_INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1";
const MAX_JWS_CHARS = 16 * 1024;
const MAX_CERT_B64_CHARS = 8 * 1024;
const SKEW_MS = 60_000;

export type JwsFailure = "malformed" | "algorithm" | "chain" | "certificate_expired" | "signature";

export class JwsVerificationError extends Error {
  constructor(public readonly reason: JwsFailure) {
    super(`jws ${reason}`);
  }
}

export type VerifiedJws = {
  header: Record<string, unknown>;
  payload: Record<string, unknown>;
  leaf: ParsedCertificate;
};

export type VerifyOptions = {
  roots: Uint8Array[];
  now: number;
  leafOid?: string;
  intermediateOid?: string;
};

function decodeJson(part: string): Record<string, unknown> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(fromUtf8(base64UrlDecode(part)));
  } catch {
    throw new JwsVerificationError("malformed");
  }
  if (!isRecord(parsed)) throw new JwsVerificationError("malformed");
  return parsed;
}

function splitCompact(compact: string): [string, string, string] {
  if (typeof compact !== "string" || compact.length === 0 || compact.length > MAX_JWS_CHARS) throw new JwsVerificationError("malformed");
  const parts = compact.split(".");
  if (parts.length !== 3 || parts.some(part => part.length === 0 && part !== parts[2])) throw new JwsVerificationError("malformed");
  return [parts[0]!, parts[1]!, parts[2]!];
}

/** Decodes without verifying. Only for `Xcode`/`LocalTesting` transactions on a developer machine. */
export function decodeJwsUnverified(compact: string): { header: Record<string, unknown>; payload: Record<string, unknown> } {
  const [header, payload] = splitCompact(compact);
  return { header: decodeJson(header), payload: decodeJson(payload) };
}

export async function verifyAppleJws(compact: string, options: VerifyOptions): Promise<VerifiedJws> {
  const [headerPart, payloadPart, signaturePart] = splitCompact(compact);
  const header = decodeJson(headerPart);
  if (header.alg !== "ES256") throw new JwsVerificationError("algorithm");
  const x5c = header.x5c;
  if (!Array.isArray(x5c) || x5c.length !== 3 || !x5c.every(item => typeof item === "string" && item.length > 0 && item.length <= MAX_CERT_B64_CHARS)) {
    throw new JwsVerificationError("chain");
  }

  let leaf: ParsedCertificate, intermediate: ParsedCertificate, root: ParsedCertificate;
  try {
    [leaf, intermediate, root] = (x5c as string[]).map(item => parseCertificate(base64Decode(item))) as [ParsedCertificate, ParsedCertificate, ParsedCertificate];
  } catch {
    throw new JwsVerificationError("chain");
  }
  if (!leaf.extensionOids.has(options.leafOid ?? APPLE_LEAF_OID)) throw new JwsVerificationError("chain");
  if (!intermediate.extensionOids.has(options.intermediateOid ?? APPLE_INTERMEDIATE_OID)) throw new JwsVerificationError("chain");
  if (options.roots.length === 0 || !options.roots.some(pinned => bytesEqual(pinned, root.der))) throw new JwsVerificationError("chain");
  if (leaf.publicKeyAlgorithm.kind !== "ec" || leaf.publicKeyAlgorithm.curve !== "P-256") throw new JwsVerificationError("algorithm");

  let chainOk: boolean;
  try {
    chainOk = (await verifySignedBy(intermediate, root)) && (await verifySignedBy(leaf, intermediate));
  } catch {
    chainOk = false;
  }
  if (!chainOk) throw new JwsVerificationError("chain");

  const payload = decodeJson(payloadPart);
  const signedDate = typeof payload.signedDate === "number" && Number.isFinite(payload.signedDate) ? payload.signedDate : undefined;
  if (signedDate !== undefined && signedDate > options.now + SKEW_MS) throw new JwsVerificationError("certificate_expired");
  const effective = signedDate ?? options.now;
  if (!validAt(leaf, effective, SKEW_MS) || !validAt(intermediate, effective, SKEW_MS) || !validAt(root, effective, SKEW_MS)) {
    throw new JwsVerificationError("certificate_expired");
  }

  let signature: Uint8Array;
  try {
    signature = base64UrlDecode(signaturePart);
  } catch {
    throw new JwsVerificationError("malformed");
  }
  if (signature.length !== 64) throw new JwsVerificationError("signature");
  const key = await importVerifyKey(leaf, "SHA-256");
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature as BufferSource, utf8(`${headerPart}.${payloadPart}`) as BufferSource);
  if (!ok) throw new JwsVerificationError("signature");
  return { header, payload, leaf };
}

/** Parses `APPLE_ROOT_CERTS` (comma-separated base64 DER). Invalid entries are dropped, not fatal. */
export function parseRootPins(value: string | undefined): Uint8Array[] {
  const pins: Uint8Array[] = [];
  for (const entry of (value ?? "").split(",").map(item => item.trim()).filter(Boolean)) {
    try {
      const der = base64Decode(entry);
      parseCertificate(der);
      pins.push(der);
    } catch {
      // ignored: a malformed pin cannot be trusted and is reported by /ready
    }
  }
  return pins;
}
