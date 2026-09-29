// Minimal DER / X.509 reader: enough to walk Apple's three-certificate JWS chains
// (ECDSA P-256 / P-384 and RSA roots) with WebCrypto. Not a general-purpose parser.

type Tlv = { tag: number; offset: number; start: number; end: number };

const OID = {
  ecPublicKey: "1.2.840.10045.2.1",
  rsaEncryption: "1.2.840.113549.1.1.1",
  p256: "1.2.840.10045.3.1.7",
  p384: "1.3.132.0.34",
  p521: "1.3.132.0.35",
  ecdsaSha256: "1.2.840.10045.4.3.2",
  ecdsaSha384: "1.2.840.10045.4.3.3",
  ecdsaSha512: "1.2.840.10045.4.3.4",
  rsaSha256: "1.2.840.113549.1.1.11",
  rsaSha384: "1.2.840.113549.1.1.12",
  rsaSha512: "1.2.840.113549.1.1.13",
} as const;

export type PublicKeyAlgorithm =
  | { kind: "ec"; curve: "P-256" | "P-384" | "P-521" }
  | { kind: "rsa" };

export type ParsedCertificate = {
  der: Uint8Array;
  tbs: Uint8Array;
  signature: Uint8Array;
  signatureAlgorithmOid: string;
  issuer: Uint8Array;
  subject: Uint8Array;
  notBefore: number;
  notAfter: number;
  spki: Uint8Array;
  publicKeyAlgorithm: PublicKeyAlgorithm;
  extensionOids: Set<string>;
};

export class DerError extends Error {}

function readTlv(bytes: Uint8Array, offset: number, limit = bytes.length): Tlv {
  if (offset + 2 > limit) throw new DerError("truncated");
  const tag = bytes[offset]!;
  if ((tag & 0x1f) === 0x1f) throw new DerError("multi-byte tags unsupported");
  let length = bytes[offset + 1]!;
  let start = offset + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 4 || start + count > bytes.length) throw new DerError("bad length");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + bytes[start + i]!;
    // DER requires the shortest encoding: no leading zero byte and no long form for lengths under 128.
    if (bytes[start] === 0 || length < 0x80) throw new DerError("non-minimal length");
    start += count;
  }
  const end = start + length;
  if (end > limit) throw new DerError("truncated value");
  return { tag, offset, start, end };
}

function children(bytes: Uint8Array, tlv: Tlv): Tlv[] {
  const out: Tlv[] = [];
  let offset = tlv.start;
  while (offset < tlv.end) {
    const child = readTlv(bytes, offset, tlv.end);
    out.push(child);
    offset = child.end;
  }
  return out;
}

const content = (bytes: Uint8Array, tlv: Tlv) => bytes.subarray(tlv.start, tlv.end);
const element = (bytes: Uint8Array, tlv: Tlv) => bytes.subarray(tlv.offset, tlv.end);

export function decodeOid(bytes: Uint8Array): string {
  if (bytes.length === 0) throw new DerError("empty OID");
  const parts: number[] = [];
  let value = 0;
  for (const byte of bytes) {
    value = value * 128 + (byte & 0x7f);
    if ((byte & 0x80) === 0) {
      if (parts.length === 0) {
        const first = value < 80 ? Math.floor(value / 40) : 2;
        parts.push(first, value - first * 40);
      } else {
        parts.push(value);
      }
      value = 0;
    }
  }
  return parts.join(".");
}

function parseTime(bytes: Uint8Array, tlv: Tlv): number {
  const text = String.fromCharCode(...content(bytes, tlv));
  if (tlv.tag === 0x17) {
    const match = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
    if (!match) throw new DerError("bad UTCTime");
    const yy = Number(match[1]);
    return Date.UTC(yy >= 50 ? 1900 + yy : 2000 + yy, Number(match[2]) - 1, Number(match[3]), Number(match[4]), Number(match[5]), Number(match[6]));
  }
  if (tlv.tag === 0x18) {
    const match = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\.\d+)?Z$/.exec(text);
    if (!match) throw new DerError("bad GeneralizedTime");
    return Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]), Number(match[4]), Number(match[5]), Number(match[6]));
  }
  throw new DerError("bad time tag");
}

function parseSpkiAlgorithm(bytes: Uint8Array, spki: Tlv): PublicKeyAlgorithm {
  const [algorithm] = children(bytes, spki);
  if (!algorithm || algorithm.tag !== 0x30) throw new DerError("bad SPKI");
  const algorithmParts = children(bytes, algorithm);
  const oid = algorithmParts[0];
  if (!oid || oid.tag !== 0x06) throw new DerError("bad SPKI algorithm");
  const algorithmOid = decodeOid(content(bytes, oid));
  if (algorithmOid === OID.rsaEncryption) return { kind: "rsa" };
  if (algorithmOid !== OID.ecPublicKey) throw new DerError("unsupported public key algorithm");
  const curve = algorithmParts[1];
  if (!curve || curve.tag !== 0x06) throw new DerError("missing EC curve");
  const curveOid = decodeOid(content(bytes, curve));
  if (curveOid === OID.p256) return { kind: "ec", curve: "P-256" };
  if (curveOid === OID.p384) return { kind: "ec", curve: "P-384" };
  if (curveOid === OID.p521) return { kind: "ec", curve: "P-521" };
  throw new DerError("unsupported EC curve");
}

export function parseCertificate(der: Uint8Array): ParsedCertificate {
  const certificate = readTlv(der, 0);
  if (certificate.tag !== 0x30 || certificate.end !== der.length) throw new DerError("not a certificate");
  const [tbs, signatureAlgorithm, signatureValue] = children(der, certificate);
  if (!tbs || !signatureAlgorithm || !signatureValue || tbs.tag !== 0x30 || signatureAlgorithm.tag !== 0x30 || signatureValue.tag !== 0x03) {
    throw new DerError("bad certificate structure");
  }
  const signatureAlgorithmOidTlv = children(der, signatureAlgorithm)[0];
  if (!signatureAlgorithmOidTlv || signatureAlgorithmOidTlv.tag !== 0x06) throw new DerError("bad signature algorithm");
  const signatureBits = content(der, signatureValue);
  if (signatureBits[0] !== 0) throw new DerError("unexpected unused bits");

  const fields = children(der, tbs);
  let index = 0;
  if (fields[index]?.tag === 0xa0) index += 1; // [0] EXPLICIT version
  const serial = fields[index++];
  const tbsSignature = fields[index++];
  const issuer = fields[index++];
  const validity = fields[index++];
  const subject = fields[index++];
  const spki = fields[index++];
  if (!serial || !tbsSignature || !issuer || !validity || !subject || !spki ||
      serial.tag !== 0x02 || issuer.tag !== 0x30 || validity.tag !== 0x30 || subject.tag !== 0x30 || spki.tag !== 0x30) {
    throw new DerError("bad TBSCertificate");
  }
  const [notBefore, notAfter] = children(der, validity);
  if (!notBefore || !notAfter) throw new DerError("bad validity");
  const tbsSignatureOid = children(der, tbsSignature)[0];
  if (!tbsSignatureOid || tbsSignatureOid.tag !== 0x06 || decodeOid(content(der, tbsSignatureOid)) !== decodeOid(content(der, signatureAlgorithmOidTlv))) {
    throw new DerError("signature algorithm mismatch");
  }

  const extensionOids = new Set<string>();
  for (; index < fields.length; index++) {
    const field = fields[index]!;
    if (field.tag !== 0xa3) continue; // [3] EXPLICIT extensions
    const [extensions] = children(der, field);
    if (!extensions || extensions.tag !== 0x30) throw new DerError("bad extensions");
    for (const extension of children(der, extensions)) {
      const [extnId] = children(der, extension);
      if (!extnId || extnId.tag !== 0x06) throw new DerError("bad extension");
      extensionOids.add(decodeOid(content(der, extnId)));
    }
  }

  return {
    der,
    tbs: element(der, tbs),
    signature: signatureBits.subarray(1),
    signatureAlgorithmOid: decodeOid(content(der, signatureAlgorithmOidTlv)),
    issuer: element(der, issuer),
    subject: element(der, subject),
    notBefore: parseTime(der, notBefore),
    notAfter: parseTime(der, notAfter),
    spki: element(der, spki),
    publicKeyAlgorithm: parseSpkiAlgorithm(der, spki),
    extensionOids,
  };
}

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.byteLength !== b.byteLength) return false;
  let diff = 0;
  for (let i = 0; i < a.byteLength; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

/** Converts a DER-encoded ECDSA signature (SEQUENCE of two INTEGERs) to the fixed-size r||s WebCrypto expects. */
export function ecdsaDerToRaw(der: Uint8Array, coordinateBytes: number): Uint8Array {
  const sequence = readTlv(der, 0);
  if (sequence.tag !== 0x30) throw new DerError("bad ECDSA signature");
  const [r, s] = children(der, sequence);
  if (!r || !s || r.tag !== 0x02 || s.tag !== 0x02) throw new DerError("bad ECDSA signature");
  const out = new Uint8Array(coordinateBytes * 2);
  for (const [integer, offset] of [[r, 0], [s, coordinateBytes]] as const) {
    let value = content(der, integer);
    while (value.length > coordinateBytes && value[0] === 0) value = value.subarray(1);
    if (value.length > coordinateBytes) throw new DerError("ECDSA integer too long");
    out.set(value, offset + coordinateBytes - value.length);
  }
  return out;
}

function hashFor(oid: string): "SHA-256" | "SHA-384" | "SHA-512" {
  switch (oid) {
    case OID.ecdsaSha256: case OID.rsaSha256: return "SHA-256";
    case OID.ecdsaSha384: case OID.rsaSha384: return "SHA-384";
    case OID.ecdsaSha512: case OID.rsaSha512: return "SHA-512";
    default: throw new DerError("unsupported signature algorithm");
  }
}

const coordinateBytes = { "P-256": 32, "P-384": 48, "P-521": 66 } as const;

export async function importVerifyKey(cert: ParsedCertificate, hash: "SHA-256" | "SHA-384" | "SHA-512"): Promise<CryptoKey> {
  if (cert.publicKeyAlgorithm.kind === "ec") {
    return crypto.subtle.importKey("spki", cert.spki as BufferSource, { name: "ECDSA", namedCurve: cert.publicKeyAlgorithm.curve }, false, ["verify"]);
  }
  return crypto.subtle.importKey("spki", cert.spki as BufferSource, { name: "RSASSA-PKCS1-v1_5", hash }, false, ["verify"]);
}

/** True when `cert` was signed by `issuer`'s key with the algorithm `cert` declares. */
export async function verifySignedBy(cert: ParsedCertificate, issuer: ParsedCertificate): Promise<boolean> {
  if (!bytesEqual(cert.issuer, issuer.subject)) return false;
  const hash = hashFor(cert.signatureAlgorithmOid);
  const key = await importVerifyKey(issuer, hash);
  if (issuer.publicKeyAlgorithm.kind === "ec") {
    if (!cert.signatureAlgorithmOid.startsWith("1.2.840.10045.4.3.")) return false;
    const raw = ecdsaDerToRaw(cert.signature, coordinateBytes[issuer.publicKeyAlgorithm.curve]);
    return crypto.subtle.verify({ name: "ECDSA", hash }, key, raw as BufferSource, cert.tbs as BufferSource);
  }
  if (!cert.signatureAlgorithmOid.startsWith("1.2.840.113549.1.1.")) return false;
  return crypto.subtle.verify({ name: "RSASSA-PKCS1-v1_5" }, key, cert.signature as BufferSource, cert.tbs as BufferSource);
}

export const validAt = (cert: ParsedCertificate, at: number, skewMs = 60_000) =>
  cert.notBefore - skewMs <= at && at <= cert.notAfter + skewMs;
