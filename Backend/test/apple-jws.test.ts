import { describe, expect, it } from "vitest";
import { JwsVerificationError, parseRootPins, verifyAppleJws } from "../src/apple/jws";
import { decodeOid, parseCertificate, verifySignedBy } from "../src/apple/x509";
import { base64Encode, utf8 } from "../src/util";
import { generateTestChain, parseChain, signCompactJws, transactionPayload, type TestChain } from "./helpers/apple-chain";
import { testEnv } from "./helpers/client";

const pinned = parseChain(testEnv.TEST_APPLE_CHAIN);
const pinnedRoots = parseRootPins(testEnv.APPLE_ROOT_CERTS);
const now = Date.now();

async function expectFailure(promise: Promise<unknown>, reason: string) {
  await expect(promise).rejects.toBeInstanceOf(JwsVerificationError);
  await promise.catch(error => expect((error as JwsVerificationError).reason).toBe(reason));
}

describe("Apple JWS verification", () => {
  it("verifies a transaction signed by the pinned chain and returns its payload", async () => {
    const jws = await signCompactJws(transactionPayload({}, now), pinned);
    const verified = await verifyAppleJws(jws, { roots: pinnedRoots, now });
    expect(verified.payload.originalTransactionId).toBe("2000000123456789");
    expect(verified.header.alg).toBe("ES256");
    expect(verified.leaf.extensionOids.has("1.2.840.113635.100.6.11.1")).toBe(true);
  });

  it("rejects a chain that ends in an unpinned root", async () => {
    const other = await generateTestChain({ now });
    await expectFailure(verifyAppleJws(await signCompactJws(transactionPayload({}, now), other), { roots: pinnedRoots, now }), "chain");
  });

  it("rejects a leaf without Apple's in-app purchase marker OID", async () => {
    const chain = await generateTestChain({ now, leafOid: null });
    await expectFailure(verifyAppleJws(await signCompactJws(transactionPayload({}, now), chain), { roots: [chain.rootDer], now }), "chain");
  });

  it("rejects an intermediate without the WWDR marker OID", async () => {
    const chain = await generateTestChain({ now, intermediateOid: null });
    await expectFailure(verifyAppleJws(await signCompactJws(transactionPayload({}, now), chain), { roots: [chain.rootDer], now }), "chain");
  });

  it("rejects chains that are not exactly three certificates", async () => {
    const two = await signCompactJws(transactionPayload({}, now), pinned, { x5c: [base64Encode(pinned.leafDer), base64Encode(pinned.rootDer)] });
    await expectFailure(verifyAppleJws(two, { roots: pinnedRoots, now }), "chain");
    const four = await signCompactJws(transactionPayload({}, now), pinned, {
      x5c: [base64Encode(pinned.leafDer), base64Encode(pinned.intermediateDer), base64Encode(pinned.rootDer), base64Encode(pinned.rootDer)],
    });
    await expectFailure(verifyAppleJws(four, { roots: pinnedRoots, now }), "chain");
  });

  it("rejects a leaf swapped for a certificate the pinned intermediate did not sign", async () => {
    const other = await generateTestChain({ now });
    const spliced = await signCompactJws(transactionPayload({}, now), other, {
      x5c: [base64Encode(other.leafDer), base64Encode(pinned.intermediateDer), base64Encode(pinned.rootDer)],
    });
    await expectFailure(verifyAppleJws(spliced, { roots: pinnedRoots, now }), "chain");
  });

  it("rejects any algorithm other than ES256", async () => {
    await expectFailure(verifyAppleJws(await signCompactJws(transactionPayload({}, now), pinned, { alg: "RS256" }), { roots: pinnedRoots, now }), "algorithm");
    await expectFailure(verifyAppleJws(await signCompactJws(transactionPayload({}, now), pinned, { alg: "none" }), { roots: pinnedRoots, now }), "algorithm");
  });

  it("rejects a tampered payload and a signature from another key", async () => {
    await expectFailure(verifyAppleJws(await signCompactJws(transactionPayload({}, now), pinned, { tamperPayload: true }), { roots: pinnedRoots, now }), "signature");
    const other = await generateTestChain({ now });
    await expectFailure(verifyAppleJws(await signCompactJws(transactionPayload({}, now), pinned, { signingKey: other.leafPrivatePkcs8 }), { roots: pinnedRoots, now }), "signature");
  });

  it("checks certificate validity at signedDate, like Apple's offline mode", async () => {
    const day = 24 * 60 * 60 * 1000;
    const chain: TestChain = await generateTestChain({ now, leafNotBefore: new Date(now - 30 * day), leafNotAfter: new Date(now - 2 * day) });
    const roots = [chain.rootDer];
    await expectFailure(verifyAppleJws(await signCompactJws(transactionPayload({ signedDate: now }, now), chain), { roots, now }), "certificate_expired");
    const signedBeforeExpiry = await signCompactJws(transactionPayload({ signedDate: now - 5 * day }, now), chain);
    expect((await verifyAppleJws(signedBeforeExpiry, { roots, now })).payload.signedDate).toBe(now - 5 * day);
    await expectFailure(verifyAppleJws(await signCompactJws(transactionPayload({ signedDate: now + 10 * 60_000 }, now), pinned), { roots: pinnedRoots, now }), "certificate_expired");
  });

  it("rejects malformed and oversized tokens without throwing anything else", async () => {
    await expectFailure(verifyAppleJws("not-a-jws", { roots: pinnedRoots, now }), "malformed");
    await expectFailure(verifyAppleJws("a.b", { roots: pinnedRoots, now }), "malformed");
    await expectFailure(verifyAppleJws(`${"e".repeat(17 * 1024)}.a.b`, { roots: pinnedRoots, now }), "malformed");
    await expectFailure(verifyAppleJws(`${btoa("{}").replace(/=/g, "")}.e30.c2ln`, { roots: pinnedRoots, now }), "algorithm");
  });

  it("refuses to verify when no root is pinned", async () => {
    await expectFailure(verifyAppleJws(await signCompactJws(transactionPayload({}, now), pinned), { roots: [], now }), "chain");
  });
});

describe("X.509 reader", () => {
  it("parses the generated root, intermediate and leaf and verifies their signatures", async () => {
    const root = parseCertificate(pinned.rootDer);
    const intermediate = parseCertificate(pinned.intermediateDer);
    const leaf = parseCertificate(pinned.leafDer);
    expect(root.publicKeyAlgorithm).toEqual({ kind: "ec", curve: "P-384" });
    expect(leaf.publicKeyAlgorithm).toEqual({ kind: "ec", curve: "P-256" });
    expect(leaf.notAfter).toBeGreaterThan(leaf.notBefore);
    expect(intermediate.extensionOids.has("1.2.840.113635.100.6.2.1")).toBe(true);
    expect(await verifySignedBy(root, root)).toBe(true);
    expect(await verifySignedBy(intermediate, root)).toBe(true);
    expect(await verifySignedBy(leaf, intermediate)).toBe(true);
    expect(await verifySignedBy(leaf, root)).toBe(false);
  });

  it("decodes object identifiers", () => {
    expect(decodeOid(Uint8Array.from([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]))).toBe("1.2.840.10045.4.3.2");
    expect(decodeOid(Uint8Array.from([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x0b, 0x01]))).toBe("1.2.840.113635.100.6.11.1");
  });

  it("drops root pins that are not certificates", () => {
    expect(parseRootPins(`${base64Encode(utf8("garbage"))},${testEnv.APPLE_ROOT_CERTS}, ,`)).toHaveLength(1);
    expect(parseRootPins(undefined)).toHaveLength(0);
  });
});
