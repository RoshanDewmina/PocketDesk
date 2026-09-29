import { runDurableObjectAlarm } from "cloudflare:test";
import { afterEach, beforeAll, expect, it, vi } from "vitest";
import { connectHost, pairing, sleep, testEnv } from "./helpers/client";
import { installTurnMock } from "./helpers/turn-mock";

beforeAll(() => { installTurnMock(); });
afterEach(() => { vi.useRealTimers(); });

it("keeps offline pairing authentication through idle cleanup until explicit forget", async () => {
  const p = await pairing();
  const host = await connectHost(p);
  host.close();
  await host.closed;
  await sleep(20);
  const stub = testEnv.ROOM.get(testEnv.ROOM.idFromName(p.room));
  expect(await stub.authenticatePush(p.room, p.clientToken)).toBe(true);
  vi.setSystemTime(Date.now() + 31 * 24 * 60 * 60_000);
  expect(await runDurableObjectAlarm(stub)).toBe(true);
  expect(await stub.authenticatePush(p.room, p.clientToken)).toBe(true);
  // An otherwise empty object no longer wakes just to preserve the pairing hash.
  expect(await runDurableObjectAlarm(stub)).toBe(false);
  await stub.forget();
  expect(await stub.authenticatePush(p.room, p.clientToken)).toBe(false);
});
