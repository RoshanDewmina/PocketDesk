import { describe, expect, it, vi } from "vitest";
import { createCloudflareTurnProvider, turnProviderFromEnv } from "../src/turn";
import { testEnv } from "./helpers/client";

const ice = { iceServers: [{ urls: ["turn:turn.cloudflare.com:3478"], username: "user", credential: "secret" }] };
const settings = { keyId: "k".repeat(32), apiToken: "t".repeat(64), ttlSeconds: 3600, timeoutMs: 3000 };

describe("TURN operational controls", () => {
  it("tags issuance with the full pseudonymous entitlement, never the transaction or device", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(Response.json(ice, { status: 201 }));
    const provider = createCloudflareTurnProvider({ ...settings, fetch: fetcher });
    await provider.issue("a".repeat(64));
    expect(JSON.parse(fetcher.mock.calls[0]![1]!.body as string)).toEqual({ ttl: 3600, customIdentifier: "a".repeat(64) });
  });

  it("stops new issuance under the emergency switch while revocations remain usable", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(new Response(null, { status: 204 }));
    const provider = turnProviderFromEnv({ ...testEnv, TURN_ISSUANCE_DISABLED: "1" } as Env, fetcher)!;
    await expect(provider.issue()).rejects.toThrow("issuance disabled");
    expect(fetcher).not.toHaveBeenCalled();
    expect(await provider.revoke(["old"])).toEqual([{ username: "old", status: "confirmed" }]);
  });

  it("opens a bounded local circuit after three failures and probes again after its cooldown", async () => {
    let now = 10_000;
    const fetcher = vi.fn<typeof fetch>().mockImplementation(async () => new Response(null, { status: 503 }));
    const provider = createCloudflareTurnProvider({ ...settings, fetch: fetcher, now: () => now });
    for (let i = 0; i < 3; i++) await expect(provider.issue()).rejects.toThrow("unavailable");
    await expect(provider.issue()).rejects.toThrow("circuit open");
    expect(fetcher).toHaveBeenCalledTimes(3);
    now += 30_000;
    fetcher.mockImplementation(async () => Response.json(ice, { status: 201 }));
    await expect(provider.issue()).resolves.toEqual(ice.iceServers);
    await expect(provider.issue()).resolves.toEqual(ice.iceServers);
    expect(fetcher).toHaveBeenCalledTimes(5);
  });

  it("disabled circuit restores provider attempts on every call", async () => {
    const fetcher = vi.fn<typeof fetch>().mockImplementation(async () => new Response(null, { status: 503 }));
    const provider = createCloudflareTurnProvider({ ...settings, fetch: fetcher, circuitBreakerEnabled: false });
    for (let i = 0; i < 4; i++) await expect(provider.issue()).rejects.toThrow("unavailable");
    expect(fetcher).toHaveBeenCalledTimes(4);
  });

  it("analytics rollback restores the original untagged request", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(Response.json(ice, { status: 201 }));
    const provider = createCloudflareTurnProvider({ ...settings, fetch: fetcher, analyticsEnabled: false });
    await provider.issue("a".repeat(64));
    expect(JSON.parse(fetcher.mock.calls[0]![1]!.body as string)).toEqual({ ttl: 3600 });
  });

  it("allows only one half-open probe and never blocks revocation", async () => {
    let now = 1;
    let release!: () => void;
    const fetcher = vi.fn<typeof fetch>().mockImplementation(async () => new Response(null, { status: 503 }));
    const provider = createCloudflareTurnProvider({ ...settings, fetch: fetcher, now: () => now });
    for (let i = 0; i < 3; i++) await expect(provider.issue()).rejects.toThrow("unavailable");
    now += 30_000;
    fetcher.mockImplementation(async (input) => {
      if (String(input).endsWith("/revoke")) return new Response(null, { status: 204 });
      await new Promise<void>(resolve => { release = resolve; });
      return Response.json(ice, { status: 201 });
    });
    const probe = provider.issue();
    await expect(provider.issue()).rejects.toThrow("circuit open");
    expect(await provider.revoke(["old"])).toEqual([{ username: "old", status: "confirmed" }]);
    release();
    await expect(probe).resolves.toEqual(ice.iceServers);
  });
});
