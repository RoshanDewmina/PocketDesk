import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config";
import { handleSignalUpgrade, handleGuestUpgrade } from "../src/gateway";
import { handleVerify, handleForget } from "../src/entitlement/verify";
import { handleNotification } from "../src/entitlement/notifications";
import { allowStrict, publicRateDecision } from "../src/ratelimit";
import type { RoomDO } from "../src/room";
import { connectHost, open, pairing, registerMessage, testEnv, sleep } from "./helpers/client";
import { parseChain, signCompactJws, transactionPayload } from "./helpers/apple-chain";

type StrictEnv = Env & { STRICT_RATE_LIMITS?: string };
const limiter = (failure: string) => failure === "missing" ? undefined : {
  limit: async () => {
    if (failure === "throwing") throw new Error("quota unavailable");
    return { success: failure !== "denied" };
  },
};
const overrides = (values: Record<string, unknown>): StrictEnv => new Proxy(testEnv, {
  get: (target, key) => typeof key === "string" && key in values ? values[key] : Reflect.get(target, key),
});
const request = (path: string, body: unknown = {}) => new Request(`https://farside.test${path}`, {
  method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
});

describe("strict public rate admission", () => {
  it.each(["missing", "throwing", "denied", "healthy"])("classifies %s and preserves boolean strict callers", async failure => {
    const binding = limiter(failure);
    const expected = failure === "healthy" ? "allowed" : failure === "denied" ? "denied" : "unavailable";
    expect(await publicRateDecision(binding, "test", "RL_TEST", {})).toBe(expected);
    expect(await allowStrict(binding, "test", "RL_TEST")).toBe(failure === "healthy");
    expect(await publicRateDecision(binding, "test", "RL_TEST", { STRICT_RATE_LIMITS: "0" })).toBe(failure === "denied" ? "denied" : "allowed");
  });

  for (const [handler, path, guest] of [[handleSignalUpgrade, "/signal", false], [handleGuestUpgrade, "/guest-signal", true]] as const) {
    it.each(["missing", "throwing", "denied"])(`${path} rejects %s before accepting a socket`, async failure => {
      const response = await handler(new Request(`https://farside.test${path}`, { headers: { upgrade: "websocket", ...(guest ? { origin: "https://farside.test" } : {}) } }), overrides({ RL_SIGNAL: limiter(failure) }));
      expect(response.status).toBe(failure === "denied" ? 429 : 503);
      expect(response.webSocket).toBeNull();
    });
    it.each(["missing", "throwing"])(`${path} restores permissive %s binding rollback`, async failure => {
      const response = await handler(new Request(`https://farside.test${path}`, { headers: { upgrade: "websocket", ...(guest ? { origin: "https://farside.test" } : {}) } }), overrides({ RL_SIGNAL: limiter(failure), STRICT_RATE_LIMITS: "0" }));
      expect(response.status).toBe(101);
      response.webSocket!.accept(); response.webSocket!.close(1000, "done");
    });
  }

  for (const [name, handler] of [["verify", handleVerify], ["forget", handleForget], ["notification", handleNotification]] as const) {
    it.each(["missing", "throwing", "denied"])(`${name} distinguishes %s from exhausted quota`, async failure => {
      const env = overrides({ [name === "notification" ? "RL_NOTIFY" : "RL_API_IP"]: limiter(failure) });
      const response = name === "verify"
        ? await handleVerify(request("/verify"), env, { waitUntil: () => {} } as unknown as ExecutionContext, loadConfig(env))
        : await (handler as typeof handleForget)(request("/api"), env, loadConfig(env));
      expect(response.status).toBe(failure === "denied" ? 429 : 503);
      expect(await response.json()).toMatchObject({ error: failure === "denied" ? "rate_limited" : "unavailable" });
    });
    it.each(["missing", "throwing"])(`${name} rolls back %s to existing request parsing`, async failure => {
      const env = overrides({ [name === "notification" ? "RL_NOTIFY" : "RL_API_IP"]: limiter(failure), STRICT_RATE_LIMITS: "0" });
      const response = name === "verify"
        ? await handleVerify(request("/verify"), env, { waitUntil: () => {} } as unknown as ExecutionContext, loadConfig(env))
        : await (handler as typeof handleForget)(request("/api"), env, loadConfig(env));
      expect(response.status).toBe(400);
    });
  }
  it.each(["missing", "throwing", "denied"])("bounds device verification with a %s binding", async failure => {
    const env = overrides({ RL_API_IP: limiter("healthy"), RL_API_DEVICE: limiter(failure) });
    const response = await handleVerify(request("/verify", { deviceId: "a".repeat(64), signedTransaction: "invalid" }), env,
      { waitUntil: () => {} } as unknown as ExecutionContext, loadConfig(env));
    expect(response.status).toBe(failure === "denied" ? 429 : 503);
  });
  it.each(["missing", "throwing"])("restores permissive device verification for %s bindings", async failure => {
    const env = overrides({ RL_API_IP: limiter("healthy"), RL_API_DEVICE: limiter(failure), STRICT_RATE_LIMITS: "0" });
    const response = await handleVerify(request("/verify", { deviceId: "a".repeat(64), signedTransaction: "invalid" }), env,
      { waitUntil: () => {} } as unknown as ExecutionContext, loadConfig(env));
    expect(response.status).toBe(401);
  });
  it.each(["missing", "throwing", "denied"])("bounds signed sandbox verification with a %s binding", async failure => {
    const env = overrides({ RL_API_IP: limiter("healthy"), RL_API_DEVICE: limiter("healthy"), RL_API_SANDBOX: limiter(failure) });
    const signedTransaction = await signCompactJws(transactionPayload({ environment: "Sandbox" }), parseChain(testEnv.TEST_APPLE_CHAIN));
    const response = await handleVerify(request("/verify", { deviceId: "a".repeat(64), signedTransaction }), env,
      { waitUntil: () => {} } as unknown as ExecutionContext, loadConfig(env));
    expect(response.status).toBe(failure === "denied" ? 429 : 503);
    expect(await response.json()).toMatchObject({ error: failure === "denied" ? "rate_limited" : "unavailable" });
  });
});

describe("room pending socket cap", () => {
  it.each([undefined, "0"])("checks native and guest capacity before upgrade (switch=%s)", async strict => {
    const p = await pairing(), rooms = testEnv.ROOM as unknown as DurableObjectNamespace<RoomDO>;
    const stub = rooms.get(rooms.idFromName(p.room));
    // An authenticated owner never consumes pending capacity. All guest sockets do:
    // GuestService.owns includes requests still awaiting signature/authority checks.
    const host = await connectHost(p, { features: ["route.1"] });
    const original: { env?: Env } = {};
    await runInDurableObject(stub, instance => {
      const internal = instance as unknown as { env: Env };
      original.env = internal.env;
      internal.env = new Proxy(internal.env, { get: (target, key) => key === "STRICT_RATE_LIMITS" ? strict : Reflect.get(target, key) });
    });
    const sockets: WebSocket[] = [];
    const connect = (guest: boolean) => stub.fetch(`https://room.internal/${guest ? "guest-connect" : "connect"}`, { headers: { upgrade: "websocket" } });
    try {
      for (let i = 0; i < 8; i++) {
        const response = await connect(i % 2 === 0);
        expect(response.status).toBe(101); response.webSocket!.accept(); sockets.push(response.webSocket!);
      }
      for (const guest of [false, true]) {
        const response = await connect(guest);
        expect(response.status).toBe(strict === "0" ? 101 : 503);
        if (response.webSocket) { response.webSocket.accept(); sockets.push(response.webSocket); }
      }
      if (strict !== "0") {
        const overflow = await open();
        overflow.send(registerMessage(p, "client", { features: ["route.1"] }));
        expect(await overflow.closed).toEqual({ code: 1013, reason: "busy" });
        expect(overflow.messages).toEqual([]);
      }
      sockets.shift()!.close(1000, "done"); await sleep(10);
      const retry = await connect(false);
      expect(retry.status).toBe(101); retry.webSocket!.accept(); sockets.push(retry.webSocket!);
    } finally {
      for (const socket of sockets) socket.close(1000, "done");
      host.close();
      await runInDurableObject(stub, instance => { (instance as unknown as { env: Env }).env = original.env!; });
    }
  });
});

describe("room creation distinguishes exhaustion and dependency outage", () => {
  for (const strict of [undefined, "0"]) {
    it.each(["missing", "throwing", "denied"])(`closes retryably or by policy for %s (switch=${strict})`, async failure => {
      const p = await pairing(), rooms = testEnv.ROOM as unknown as DurableObjectNamespace<RoomDO>;
      const stub = rooms.get(rooms.idFromName(p.room));
      let originalEnv: Env;
      await runInDurableObject(stub, instance => {
        const internals = instance as unknown as { env: Env };
        originalEnv = internals.env;
        internals.env = new Proxy(internals.env, { get: (target, key) => key === "RL_ROOM_CREATE" ? limiter(failure) : key === "STRICT_RATE_LIMITS" ? strict : Reflect.get(target, key) });
      });
      const host = await open();
      try {
        host.send(registerMessage(p, "host", { features: ["route.1"] }));
        expect(await host.closed).toEqual({ code: strict !== "0" && failure === "denied" ? 1008 : 1013,
          reason: strict !== "0" && failure !== "denied" ? "rate_limit_unavailable" : "rate_limited" });
        expect(host.messages).toEqual([]);
        expect(await stub.snapshot()).toMatchObject({ hostOnline: false, liveCredentials: 0 });
      } finally {
        host.close();
        await runInDurableObject(stub, instance => { (instance as unknown as { env: Env }).env = originalEnv; });
      }
    });
  }
});
