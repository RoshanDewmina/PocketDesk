// Generates a throwaway three-certificate chain shaped like Apple's (root P-384, WWDR-style
// intermediate with OID 1.2.840.113635.100.6.2.1, leaf with OID 1.2.840.113635.100.6.11.1) and
// signs compact JWS with it. Pure WebCrypto + a small DER encoder, so it runs in Node (vitest
// config) and in workerd (tests). Keys never leave the process.

import { base64Encode, base64Decode, base64UrlEncode, utf8 } from "../../src/util.ts";

const subtle = crypto.subtle;

function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) { out.set(part, offset); offset += part.length; }
  return out;
}

function lengthBytes(length: number): number[] {
  if (length < 0x80) return [length];
  const bytes: number[] = [];
  let value = length;
  while (value > 0) { bytes.unshift(value & 0xff); value = Math.floor(value / 256); }
  return [0x80 | bytes.length, ...bytes];
}

export const der = {
  tlv: (tag: number, body: Uint8Array) => concat([Uint8Array.from([tag, ...lengthBytes(body.length)]), body]),
  seq: (...items: Uint8Array[]) => der.tlv(0x30, concat(items)),
  set: (...items: Uint8Array[]) => der.tlv(0x31, concat(items)),
  int: (bytes: Uint8Array) => {
    let value = bytes;
    while (value.length > 1 && value[0] === 0 && (value[1]! & 0x80) === 0) value = value.subarray(1);
    if (value[0]! & 0x80) value = concat([Uint8Array.of(0), value]);
    return der.tlv(0x02, value);
  },
  oid: (text: string) => {
    const parts = text.split(".").map(Number);
    const bytes = [parts[0]! * 40 + parts[1]!];
    for (const part of parts.slice(2)) {
      const stack = [part & 0x7f];
      let value = Math.floor(part / 128);
      while (value > 0) { stack.unshift((value & 0x7f) | 0x80); value = Math.floor(value / 128); }
      bytes.push(...stack);
    }
    return der.tlv(0x06, Uint8Array.from(bytes));
  },
  utf8String: (text: string) => der.tlv(0x0c, utf8(text)),
  utcTime: (date: Date) => {
    const pad = (n: number) => String(n).padStart(2, "0");
    return der.tlv(0x17, utf8(`${pad(date.getUTCFullYear() % 100)}${pad(date.getUTCMonth() + 1)}${pad(date.getUTCDate())}${pad(date.getUTCHours())}${pad(date.getUTCMinutes())}${pad(date.getUTCSeconds())}Z`));
  },
  bitString: (bytes: Uint8Array) => der.tlv(0x03, concat([Uint8Array.of(0), bytes])),
  octetString: (bytes: Uint8Array) => der.tlv(0x04, bytes),
  explicit: (n: number, inner: Uint8Array) => der.tlv(0xa0 | n, inner),
  null: () => der.tlv(0x05, new Uint8Array(0)),
  boolTrue: () => der.tlv(0x01, Uint8Array.of(0xff)),
};

const name = (commonName: string) => der.seq(der.set(der.seq(der.oid("2.5.4.3"), der.utf8String(commonName))));

const SIG_OID = { "SHA-256": "1.2.840.10045.4.3.2", "SHA-384": "1.2.840.10045.4.3.3" } as const;
const COORD = { "P-256": 32, "P-384": 48 } as const;

type Curve = keyof typeof COORD;
type Hash = keyof typeof SIG_OID;

export type KeyPairDer = { publicKey: CryptoKey; privateKey: CryptoKey; spki: Uint8Array; curve: Curve };

export async function generateKey(curve: Curve): Promise<KeyPairDer> {
  const pair = (await subtle.generateKey({ name: "ECDSA", namedCurve: curve }, true, ["sign", "verify"])) as CryptoKeyPair;
  const spki = (await subtle.exportKey("spki", pair.publicKey)) as ArrayBuffer;
  return { publicKey: pair.publicKey, privateKey: pair.privateKey, spki: new Uint8Array(spki), curve };
}

function rawToDerSignature(raw: Uint8Array, coordinateBytes: number): Uint8Array {
  return der.seq(der.int(raw.subarray(0, coordinateBytes)), der.int(raw.subarray(coordinateBytes)));
}

export type CertificateOptions = {
  subject: string;
  issuer: string;
  subjectKey: KeyPairDer;
  issuerKey: KeyPairDer;
  hash: Hash;
  notBefore: Date;
  notAfter: Date;
  serial: number;
  extensionOids?: string[];
};

export async function makeCertificate(options: CertificateOptions): Promise<Uint8Array> {
  const extensions = (options.extensionOids ?? []).map(oid => der.seq(der.oid(oid), der.octetString(der.null())));
  const tbs = der.seq(
    der.explicit(0, der.int(Uint8Array.of(2))),
    der.int(Uint8Array.of(options.serial)),
    der.seq(der.oid(SIG_OID[options.hash])),
    name(options.issuer),
    der.seq(der.utcTime(options.notBefore), der.utcTime(options.notAfter)),
    name(options.subject),
    options.subjectKey.spki,
    ...(extensions.length ? [der.explicit(3, der.seq(...extensions))] : []),
  );
  const raw = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: options.hash }, options.issuerKey.privateKey, tbs as BufferSource));
  return der.seq(tbs, der.seq(der.oid(SIG_OID[options.hash])), der.bitString(rawToDerSignature(raw, COORD[options.issuerKey.curve])));
}

export const APPLE_LEAF_OID = "1.2.840.113635.100.6.11.1";
export const APPLE_INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1";

export type TestChain = {
  rootDer: Uint8Array;
  intermediateDer: Uint8Array;
  leafDer: Uint8Array;
  leafPrivatePkcs8: Uint8Array;
};

export type ChainOptions = {
  now?: number;
  leafOid?: string | null;
  intermediateOid?: string | null;
  leafNotAfter?: Date;
  leafNotBefore?: Date;
};

export async function generateTestChain(options: ChainOptions = {}): Promise<TestChain> {
  const now = options.now ?? Date.now();
  const day = 24 * 60 * 60 * 1000;
  const rootKey = await generateKey("P-384");
  const intermediateKey = await generateKey("P-256");
  const leafKey = await generateKey("P-256");
  const rootDer = await makeCertificate({
    subject: "Test Root CA - G3", issuer: "Test Root CA - G3", subjectKey: rootKey, issuerKey: rootKey, hash: "SHA-384",
    notBefore: new Date(now - 30 * day), notAfter: new Date(now + 3650 * day), serial: 1,
  });
  const intermediateDer = await makeCertificate({
    subject: "Test WWDR CA - G6", issuer: "Test Root CA - G3", subjectKey: intermediateKey, issuerKey: rootKey, hash: "SHA-384",
    notBefore: new Date(now - 20 * day), notAfter: new Date(now + 3000 * day), serial: 2,
    extensionOids: options.intermediateOid === null ? [] : [options.intermediateOid ?? APPLE_INTERMEDIATE_OID],
  });
  const leafDer = await makeCertificate({
    subject: "Test Prod ECC Mac App Store and iTunes Store Receipt Signing", issuer: "Test WWDR CA - G6",
    subjectKey: leafKey, issuerKey: intermediateKey, hash: "SHA-256",
    notBefore: options.leafNotBefore ?? new Date(now - 10 * day), notAfter: options.leafNotAfter ?? new Date(now + 700 * day), serial: 3,
    extensionOids: options.leafOid === null ? [] : [options.leafOid ?? APPLE_LEAF_OID],
  });
  return { rootDer, intermediateDer, leafDer, leafPrivatePkcs8: new Uint8Array((await subtle.exportKey("pkcs8", leafKey.privateKey)) as ArrayBuffer) };
}

export function serializeChain(chain: TestChain): string {
  return JSON.stringify({
    root: base64Encode(chain.rootDer), intermediate: base64Encode(chain.intermediateDer),
    leaf: base64Encode(chain.leafDer), key: base64Encode(chain.leafPrivatePkcs8),
  });
}

export function parseChain(text: string): TestChain {
  const parsed = JSON.parse(text) as { root: string; intermediate: string; leaf: string; key: string };
  return {
    rootDer: base64Decode(parsed.root), intermediateDer: base64Decode(parsed.intermediate),
    leafDer: base64Decode(parsed.leaf), leafPrivatePkcs8: base64Decode(parsed.key),
  };
}

export type JwsOptions = {
  alg?: string;
  x5c?: string[];
  signingKey?: Uint8Array;
  tamperPayload?: boolean;
};

export async function signCompactJws(payload: Record<string, unknown>, chain: TestChain, options: JwsOptions = {}): Promise<string> {
  const header = { alg: options.alg ?? "ES256", x5c: options.x5c ?? [base64Encode(chain.leafDer), base64Encode(chain.intermediateDer), base64Encode(chain.rootDer)] };
  const headerPart = base64UrlEncode(utf8(JSON.stringify(header)));
  const payloadPart = base64UrlEncode(utf8(JSON.stringify(payload)));
  const key = await subtle.importKey("pkcs8", (options.signingKey ?? chain.leafPrivatePkcs8) as BufferSource, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8(`${headerPart}.${payloadPart}`) as BufferSource));
  const signedPayload = options.tamperPayload ? base64UrlEncode(utf8(JSON.stringify({ ...payload, tampered: true }))) : payloadPart;
  return `${headerPart}.${signedPayload}.${base64UrlEncode(signature)}`;
}

/** A StoreKit-2-shaped transaction payload (JWSTransactionDecodedPayload) with sensible defaults. */
export function transactionPayload(overrides: Record<string, unknown> = {}, now = Date.now()): Record<string, unknown> {
  return {
    transactionId: "2000000123456789",
    originalTransactionId: "2000000123456789",
    webOrderLineItemId: "2000000012345678",
    bundleId: "com.roshan.PocketDesk.Remote",
    productId: "com.roshan.PocketDesk.remote.monthly",
    subscriptionGroupIdentifier: "21567890",
    purchaseDate: now - 60_000,
    originalPurchaseDate: now - 60_000,
    expiresDate: now + 30 * 24 * 60 * 60 * 1000,
    quantity: 1,
    type: "Auto-Renewable Subscription",
    inAppOwnershipType: "PURCHASED",
    signedDate: now - 1000,
    environment: "Production",
    transactionReason: "PURCHASE",
    storefront: "CAN",
    storefrontId: "143455",
    price: 5990,
    currency: "CAD",
    appTransactionId: "704000000000001",
    ...overrides,
  };
}
