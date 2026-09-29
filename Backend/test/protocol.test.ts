import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config";
import { iceWithinClientLimits, parseAuthenticatedFrame, parseJsonFrame, parseRegister } from "../src/protocol";
import { createCloudflareTurnProvider, validateIceServers } from "../src/turn";
import { testEnv } from "./helpers/client";

const room = "a".repeat(64), token = "b".repeat(64), hash = "c".repeat(64);
const host = { type: "register", version: 1, role: "host", room, token, clientTokenHash: hash };

describe("register parsing", () => {
  it("accepts the documented shapes and ignores unknown fields", () => {
    expect(parseRegister(host)?.role).toBe("host");
    expect(parseRegister({ ...host, extra: 1 })?.room).toBe(room);
    const client = parseRegister({ type: "register", version: 1, role: "client", room, token, features: ["renew.1", "remote.1", "future.9"], entitlement: "fe1.x.y" });
    expect([...client!.features]).toEqual(["renew.1", "remote.1", "future.9"]);
    expect(client!.entitlement).toBe("fe1.x.y");
  });

  it("rejects wrong versions, roles, hex, feature lists and oversized tokens", () => {
    expect(parseRegister({ ...host, version: 2 })).toBeUndefined();
    expect(parseRegister({ ...host, role: "admin" })).toBeUndefined();
    expect(parseRegister({ ...host, room: room.toUpperCase() })).toBeUndefined();
    expect(parseRegister({ ...host, token: token.slice(1) })).toBeUndefined();
    expect(parseRegister({ ...host, clientTokenHash: "nope" })).toBeUndefined();
    expect(parseRegister({ ...host, features: "renew.1" })).toBeUndefined();
    expect(parseRegister({ ...host, features: ["Bad Feature"] })).toBeUndefined();
    expect(parseRegister({ ...host, features: Array.from({ length: 9 }, (_, i) => `f${i}`) })).toBeUndefined();
    expect(parseRegister({ ...host, entitlement: "x".repeat(513) })).toBeUndefined();
    expect(parseRegister({ ...host, entitlement: "" })).toBeUndefined();
    expect(parseRegister({ type: "signal", payload: "x".repeat(64) })).toBeUndefined();
  });

  it("parses authenticated frames strictly", () => {
    expect(parseAuthenticatedFrame({ type: "renew" })).toEqual({ kind: "renew" });
    expect(parseAuthenticatedFrame({ type: "renew", x: 1 })).toEqual({ kind: "invalid", code: "invalid_message" });
    expect(parseAuthenticatedFrame({ type: "signal", payload: "A".repeat(64) })).toEqual({ kind: "signal", payload: "A".repeat(64) });
    expect(parseAuthenticatedFrame({ type: "signal", payload: "A".repeat(39) }).kind).toBe("invalid");
    expect(parseAuthenticatedFrame({ type: "signal", payload: "A".repeat(180 * 1024 + 1) }).kind).toBe("invalid");
    expect(parseAuthenticatedFrame({ type: "signal", payload: "not base64!".repeat(8) }).kind).toBe("invalid");
    expect(parseAuthenticatedFrame({ type: "register" }).kind).toBe("invalid");
  });

  it("bounds JSON frames", () => {
    expect(parseJsonFrame("{")).toBeUndefined();
    expect(parseJsonFrame("[]")).toBeUndefined();
    expect(parseJsonFrame("1")).toBeUndefined();
    expect(parseJsonFrame(`{"a":"${"x".repeat(200 * 1024)}"}`)).toBeUndefined();
    expect(parseJsonFrame(new ArrayBuffer(4))).toBeUndefined();
    expect(parseJsonFrame('{"type":"renew"}')).toEqual({ type: "renew" });
  });
});

describe("TURN provider", () => {
  const good = { urls: ["turn:turn.cloudflare.com:3478?transport=udp"], username: "u", credential: "c" };

  it("validates provider output against the native client limits", () => {
    expect(validateIceServers([{ urls: "stun:stun.cloudflare.com:3478" }, good])).toHaveLength(2);
    expect(() => validateIceServers([{ urls: ["stun:only.example.test"] }])).toThrow("no relay");
    expect(() => validateIceServers([{ urls: ["turn:no.credential.example"] }])).toThrow("invalid");
    expect(() => validateIceServers([{ urls: ["http://not.ice"] , username: "u", credential: "c" }])).toThrow("invalid");
    expect(() => validateIceServers(Array.from({ length: 9 }, () => good))).toThrow("invalid");
    expect(() => validateIceServers([{ ...good, urls: Array.from({ length: 9 }, () => good.urls[0]!) }])).toThrow("invalid");
    expect(() => validateIceServers([])).toThrow("invalid");
    expect(iceWithinClientLimits(Array.from({ length: 9 }, () => good))).toBe(false);
  });

  it("calls Cloudflare's documented endpoints and fails closed on anything unexpected", async () => {
    const calls: Array<{ url: string; method?: string; authorization: string | null; body: string | null }> = [];
    const fetcher: typeof fetch = async (input, init) => {
      const url = String(input);
      calls.push({ url, method: init?.method, authorization: new Headers(init?.headers).get("authorization"), body: init?.body ? String(init.body) : null });
      if (url.endsWith("/generate-ice-servers")) return Response.json({ iceServers: [good] }, { status: 201 });
      return new Response(null, { status: 204 });
    };
    const provider = createCloudflareTurnProvider({ keyId: "k".repeat(32), apiToken: "t".repeat(64), ttlSeconds: 900, timeoutMs: 100, fetch: fetcher });
    expect(await provider.issue()).toEqual([good]);
    expect(calls[0]).toEqual({
      url: `https://rtc.live.cloudflare.com/v1/turn/keys/${"k".repeat(32)}/credentials/generate-ice-servers`,
      method: "POST", authorization: `Bearer ${"t".repeat(64)}`, body: JSON.stringify({ ttl: 900 }),
    });
    await provider.revoke(["u", "u"]);
    expect(calls.filter(call => call.url.endsWith("/revoke"))).toHaveLength(1);
    expect(calls[1]!.url).toBe(`https://rtc.live.cloudflare.com/v1/turn/keys/${"k".repeat(32)}/credentials/u/revoke`);

    const rejecting = createCloudflareTurnProvider({ keyId: "k".repeat(32), apiToken: "t".repeat(64), ttlSeconds: 900, timeoutMs: 100, fetch: async () => new Response("denied", { status: 401 }) });
    await expect(rejecting.issue()).rejects.toThrow("unavailable");
    const oversized = createCloudflareTurnProvider({ keyId: "k".repeat(32), apiToken: "t".repeat(64), ttlSeconds: 900, timeoutMs: 100,
      fetch: async () => new Response(JSON.stringify({ padding: "x".repeat(65 * 1024), iceServers: [good] }), { status: 201 }) });
    await expect(oversized.issue()).rejects.toThrow("unavailable");
    const hanging = createCloudflareTurnProvider({ keyId: "k".repeat(32), apiToken: "t".repeat(64), ttlSeconds: 900, timeoutMs: 20,
      fetch: ((_input: RequestInfo | URL, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
      })) as typeof fetch });
    await expect(hanging.issue()).rejects.toThrow("unavailable");
    expect(() => createCloudflareTurnProvider({ keyId: "short", apiToken: "t".repeat(64), ttlSeconds: 900, timeoutMs: 100 })).toThrow("key ID");
    expect(() => createCloudflareTurnProvider({ keyId: "k".repeat(32), apiToken: "short", ttlSeconds: 900, timeoutMs: 100 })).toThrow("API token");
  });
});

describe("configuration guards", () => {
  const base = { ...testEnv } as unknown as Record<string, string>;

  it("refuses test switches in production and inconsistent lifetimes", () => {
    expect(() => loadConfig({ ...base, ENVIRONMENT_NAME: "production", ALLOW_XCODE_TRANSACTIONS: "1" } as unknown as Env)).toThrow("ALLOW_XCODE_TRANSACTIONS");
    expect(() => loadConfig({ ...base, ENVIRONMENT_NAME: "production", TEST_FORCE_RELAY: "1" } as unknown as Env)).toThrow("TEST_FORCE_RELAY");
    expect(() => loadConfig({ ...base, ROOM_LEASE_SECONDS: "3600", TURN_CREDENTIAL_TTL_SECONDS: "3600" } as unknown as Env)).toThrow("ROOM_LEASE_SECONDS");
    expect(() => loadConfig({ ...base, TEST_FORCE_RELAY: "1", CLOUDFLARE_TURN_KEY_ID: "" } as unknown as Env)).toThrow("TURN credentials");
    expect(() => loadConfig({ ...base, STUN_URLS: "http://nope" } as unknown as Env)).toThrow("STUN_URLS");
    expect(() => loadConfig({ ...base, APP_APPLE_ID: "abc" } as unknown as Env)).toThrow("APP_APPLE_ID");
  });

  it("reads the test configuration", () => {
    const config = loadConfig(testEnv);
    expect(config.environmentName).toBe("test");
    expect(config.isProduction).toBe(false);
    expect(config.allowXcode).toBe(false);
    expect(config.acceptSandbox).toBe(true);
    expect(config.relayConfigured).toBe(true);
    expect(config.roots).toHaveLength(1);
    expect([...config.allowedProductIds]).toEqual(["com.roshan.PocketDesk.remote.monthly", "com.roshan.PocketDesk.remote.yearly"]);
    expect(config.leaseMs).toBe(1800 * 1000);
  });
});
