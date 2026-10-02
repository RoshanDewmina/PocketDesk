import { runInDurableObject } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import type { Config } from "../src/config";
import { setRoomStatus } from "../src/entitlement/store";
import { mintEntitlementToken, verifyEntitlementToken } from "../src/entitlement/token";
import type { RoomDO } from "../src/room";
import { randomHex } from "../src/util";
import { parseChain, signCompactJws, transactionPayload, type TestChain } from "./helpers/apple-chain";
import { connectHost, open, pairing, postJson, registerMessage, testEnv } from "./helpers/client";
import { installTurnMock, type TurnMock } from "./helpers/turn-mock";

const rooms = () => testEnv.ROOM as unknown as DurableObjectNamespace<RoomDO>;
const stubFor = (room: string) => rooms().get(rooms().idFromName(room));
const features = ["route.1", "remote.1"];
type RoomInternals = { env: Env; config: Config };
type LimiterBinding = "RL_ROOM_CREATE" | "RL_TURN" | "RL_TURN_ENTITLEMENT";
let chain: TestChain;
let turn: TurnMock;

beforeAll(() => {
  chain = parseChain(testEnv.TEST_APPLE_CHAIN);
  turn = installTurnMock();
});

/** Inject a binding outage into this room only, exercising public deployment policy. */
async function overrideRoom(room: string, key: keyof Env, value: unknown): Promise<() => Promise<void>> {
  const stub = stubFor(room);
  let originalEnv: Env;
  let originalConfig: Config;
  await runInDurableObject(stub, instance => {
    const internals = instance as unknown as RoomInternals;
    originalEnv = internals.env;
    originalConfig = internals.config;
    internals.env = new Proxy(originalEnv, {
      get(target, property) { return property === key ? value : Reflect.get(target, property); },
    });
    internals.config = { ...originalConfig, environmentName: "staging" };
  });
  return () => runInDurableObject(stub, instance => {
    const internals = instance as unknown as RoomInternals;
    internals.env = originalEnv;
    internals.config = originalConfig;
  });
}

async function paidToken(): Promise<string> {
  const signedTransaction = await signCompactJws(transactionPayload({ originalTransactionId: `admission-${randomHex(6)}` }, Date.now()), chain);
  const response = await postJson("/v1/entitlements/verify", { signedTransaction, deviceId: randomHex() });
  const body = await response.json() as { entitled?: boolean; entitlementToken?: string };
  expect(body.entitled).toBe(true);
  // This room exercises staging policy; keep the fabricated paid token bound to that deployment.
  const payload = await verifyEntitlementToken(testEnv.ENTITLEMENT_TOKEN_KEY, body.entitlementToken!, Date.now(), "test");
  expect(payload).toBeDefined();
  return mintEntitlementToken(testEnv.ENTITLEMENT_TOKEN_KEY, { ...payload!, e: "staging" });
}

const unavailableLimiter = (failure: string) => failure === "missing" ? undefined : {
  limit: async () => {
    if (failure === "throwing") throw new Error("quota unavailable");
    return { success: false };
  },
};

describe("fail-closed public admission", () => {
  it.each(["throwing", "timeout"])("rejects a %s block lookup retryably and checks blocks again on retry", async failure => {
    const p = await pairing();
    const statement = {
      bind: () => statement,
      first: () => failure === "throwing" ? Promise.reject(new Error("D1 unavailable")) : new Promise(() => {}),
    };
    const restore = await overrideRoom(p.room, "DB", { prepare: () => statement });
    const host = await open();
    try {
      host.send(registerMessage(p, "host", { features }));
      expect(await host.closed).toEqual({ code: 1013, reason: "room_status_unavailable" });
      expect(host.messages).toEqual([]);
      expect(await stubFor(p.room).snapshot()).toMatchObject({ hostOnline: false, leaseEndsAt: null, blocked: false, liveCredentials: 0 });
      expect(await stubFor(p.room).authenticatePush(p.room, p.clientToken)).toBe(false);
    } finally {
      await restore(); host.close();
    }
    // A failed lookup must not seed a room that skips D1 on its next admission.
    await setRoomStatus(testEnv.DB, p.room, "blocked", Date.now());
    const retry = await open();
    retry.send(registerMessage(p, "host", { features }));
    expect(await retry.next()).toEqual({ type: "error", code: "room_not_approved" });
    expect((await retry.closed).reason).toBe("room_not_approved");
  });

  it.each(["missing", "throwing", "denied"])("rejects room creation with a %s quota binding and admits a later healthy retry", async failure => {
    const p = await pairing();
    const restore = await overrideRoom(p.room, "RL_ROOM_CREATE", unavailableLimiter(failure));
    const host = await open();
    try {
      host.send(registerMessage(p, "host", { features }));
      expect(await host.closed).toEqual({ code: 1013, reason: "rate_limited" });
      expect(host.messages).toEqual([]);
      expect(await stubFor(p.room).snapshot()).toMatchObject({ hostOnline: false, leaseEndsAt: null, liveCredentials: 0 });
    } finally {
      await restore(); host.close();
    }
    const retry = await connectHost(p, { features });
    expect(retry.registered.type).toBe("registered");
    retry.close();
  });

  for (const binding of ["RL_TURN", "RL_TURN_ENTITLEMENT"] satisfies LimiterBinding[]) {
    it.each(["missing", "throwing", "denied"])(`does not call TURN when ${binding} is %s`, async failure => {
      turn.reset();
      const token = await paidToken();
      const p = await pairing();
      const host = await connectHost(p, { features });
      const restore = await overrideRoom(p.room, binding, unavailableLimiter(failure));
      const client = await open();
      try {
        client.send(registerMessage(p, "client", { features, entitlement: token }));
        expect(await client.next()).toEqual({ type: "error", code: "relay_unavailable" });
        expect((await client.closed).reason).toBe("relay_unavailable");
        expect(turn.generateCalls).toBe(0);
        expect(turn.issued).toEqual([]);
        expect(await stubFor(p.room).snapshot()).toMatchObject({ hostOnline: true, clientOnline: false, entitled: false, liveCredentials: 0 });
      } finally {
        await restore(); client.close(); host.close();
      }
    });
  }
});
