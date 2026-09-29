import { describe, expect, it } from "vitest";
import { mintEntitlementToken, verifyEntitlementToken, type EntitlementTokenPayload } from "../src/entitlement/token";

const key = "unit-test-key-0123456789abcdef0123456789abcdef";
const now = Date.now();
const payload: EntitlementTokenPayload = { v: 1, d: "a".repeat(64), s: "b".repeat(64), x: Math.floor(now / 1000) + 3600, n: "P", e: "test" };

describe("entitlement token", () => {
  it("round-trips a payload and is opaque but bounded", async () => {
    const token = await mintEntitlementToken(key, payload);
    expect(token.startsWith("fe1.")).toBe(true);
    expect(token.length).toBeLessThanOrEqual(512);
    expect(await verifyEntitlementToken(key, token, now, "test")).toEqual(payload);
  });

  it("rejects tampering, another key, another deployment, expiry and malformed input", async () => {
    const token = await mintEntitlementToken(key, payload);
    const [prefix, body, signature] = token.split(".") as [string, string, string];
    expect(await verifyEntitlementToken(key, `${prefix}.${body}.${signature.slice(0, -2)}AA`, now, "test")).toBeUndefined();
    const forgedBody = btoa(JSON.stringify({ ...payload, d: "c".repeat(64) })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    expect(await verifyEntitlementToken(key, `${prefix}.${forgedBody}.${signature}`, now, "test")).toBeUndefined();
    expect(await verifyEntitlementToken("another-key-0123456789abcdef0123456789abcdef", token, now, "test")).toBeUndefined();
    expect(await verifyEntitlementToken(key, token, now, "production")).toBeUndefined();
    expect(await verifyEntitlementToken(key, token, (payload.x + 1) * 1000, "test")).toBeUndefined();
    expect(await verifyEntitlementToken(key, "fe0.a.b", now, "test")).toBeUndefined();
    expect(await verifyEntitlementToken(key, "", now, "test")).toBeUndefined();
    expect(await verifyEntitlementToken(key, "fe1." + "x".repeat(600), now, "test")).toBeUndefined();
  });

  it("rejects payloads with the wrong shape even when correctly signed", async () => {
    const bad = await mintEntitlementToken(key, { ...payload, d: "short" } as unknown as EntitlementTokenPayload);
    expect(await verifyEntitlementToken(key, bad, now, "test")).toBeUndefined();
    const noEnvironment = await mintEntitlementToken(key, { v: 1, d: payload.d, s: payload.s, x: payload.x, n: "P" } as unknown as EntitlementTokenPayload);
    expect(await verifyEntitlementToken(key, noEnvironment, now, "test")).toBeUndefined();
  });
});
