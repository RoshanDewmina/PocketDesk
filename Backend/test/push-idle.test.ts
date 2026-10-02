import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeAll, expect, it, vi } from "vitest";
import type { RoomDO } from "../src/room";
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
  expect(await runInDurableObject(stub, (instance: RoomDO) =>
    (instance as unknown as { ctx: DurableObjectState }).ctx.storage.sql.exec<{ room: string | null }>("SELECT room FROM room WHERE id=1").one().room))
    .toBeNull();
  expect(await stub.authenticatePush(p.room, p.clientToken)).toBe(true);
  // The object retains offline opt-out authority through its separate one-year retention window.
  await runDurableObjectAlarm(stub);
  expect(await stub.authenticatePush(p.room, p.clientToken)).toBe(true);
  vi.setSystemTime(Date.now() + 336 * 24 * 60 * 60_000);
  expect(await runDurableObjectAlarm(stub)).toBe(true);
  expect(await stub.authenticatePush(p.room, p.clientToken)).toBe(false);
  await stub.forget();
  expect(await stub.authenticatePush(p.room, p.clientToken)).toBe(false);
});

it("does not expire an aged pairing while an authenticated host still has live session authority", async () => {
  vi.setSystemTime(Date.now() + 366 * 24 * 60 * 60_000);
  const p = await pairing();
  const host = await connectHost(p);
  const stub = testEnv.ROOM.get(testEnv.ROOM.idFromName(p.room));
  await runInDurableObject(stub, async (instance: RoomDO) => {
    const context = (instance as unknown as { ctx: DurableObjectState }).ctx;
    context.storage.sql.exec("UPDATE push_pairing SET updated_at=? WHERE id=1", Date.now() - 366 * 24 * 60 * 60_000);
    await context.storage.setAlarm(Date.now() + 1000);
  });
  vi.setSystemTime(Date.now() + 1001);
  expect(await runDurableObjectAlarm(stub)).toBe(true);
  expect(await stub.authenticatePush(p.room, p.clientToken)).toBe(true);
  host.close();
  await host.closed;
});

it("seeds the one-year timestamp when an existing DO has the legacy pairing schema", async () => {
  const p = await pairing();
  const host = await connectHost(p);
  host.close();
  await host.closed;
  const stub = testEnv.ROOM.get(testEnv.ROOM.idFromName(p.room));
  const migrationAt = Date.now();
  await runInDurableObject(stub, async (instance: RoomDO) => {
    const context = (instance as unknown as { ctx: DurableObjectState }).ctx;
    context.storage.sql.exec("ALTER TABLE push_pairing RENAME TO push_pairing_current");
    context.storage.sql.exec("CREATE TABLE push_pairing (id INTEGER PRIMARY KEY CHECK (id=1), room TEXT NOT NULL, client_hash TEXT NOT NULL)");
    context.storage.sql.exec("INSERT INTO push_pairing (id,room,client_hash) SELECT id,room,client_hash FROM push_pairing_current");
    context.storage.sql.exec("DROP TABLE push_pairing_current");
    (instance as unknown as { ensureSchema(): void }).ensureSchema();
    await (instance as unknown as { scheduleAlarm(): Promise<void> }).scheduleAlarm();
  });
  const timestamp = await runInDurableObject(stub, (instance: RoomDO) => {
    const context = (instance as unknown as { ctx: DurableObjectState }).ctx;
    return context.storage.sql.exec<{ updated_at: number }>("SELECT updated_at FROM push_pairing WHERE id=1").one().updated_at;
  });
  expect(timestamp).toBeGreaterThanOrEqual(migrationAt);
  vi.setSystemTime(migrationAt + 31 * 24 * 60 * 60_000);
  expect(await runDurableObjectAlarm(stub)).toBe(true);
  const retentionAlarm = await runInDurableObject(stub, (instance: RoomDO) => {
    const context = (instance as unknown as { ctx: DurableObjectState }).ctx;
    return context.storage.getAlarm();
  });
  expect(retentionAlarm).toBe(timestamp + 365 * 24 * 60 * 60_000);
  expect(await stub.authenticatePush(p.room, p.clientToken)).toBe(true);
});

it("retention rollback keeps offline pairing hashes indefinitely", async () => {
  const envWithSwitch = testEnv as unknown as Env & { PUSH_PAIRING_RETENTION_ENABLED?: string };
  envWithSwitch.PUSH_PAIRING_RETENTION_ENABLED = "0";
  try {
    const p = await pairing();
    const host = await connectHost(p);
    host.close();
    await host.closed;
    vi.setSystemTime(Date.now() + 366 * 24 * 60 * 60_000);
    const stub = testEnv.ROOM.get(testEnv.ROOM.idFromName(p.room));
    await runDurableObjectAlarm(stub);
    expect(await stub.authenticatePush(p.room, p.clientToken)).toBe(true);
  } finally {
    envWithSwitch.PUSH_PAIRING_RETENTION_ENABLED = "1";
  }
});

it("retention rollback restores the baseline idle schedule when another alarm is pending", async () => {
  const p = await pairing();
  const host = await connectHost(p);
  host.close();
  await host.closed;
  await sleep(20);
  const stub = testEnv.ROOM.get(testEnv.ROOM.idFromName(p.room));
  const now = Date.now(), day = 24 * 60 * 60_000;
  await runInDurableObject(stub, async (instance: RoomDO) => {
    const internal = instance as unknown as { ctx: DurableObjectState; env: Env; scheduleAlarm(): Promise<void> };
    internal.ctx.storage.sql.exec("UPDATE room SET last_activity=?,lease_ends_at=NULL,route_expires_at=NULL WHERE id=1", now - 10 * day);
    internal.ctx.storage.sql.exec("INSERT INTO credentials (username,role,issued_at,expires_at,revoke_pending,revoke_attempts,next_revoke_at) VALUES ('test-retention-schedule','host',?,?,1,0,?)", now, now + 50 * day, now + 40 * day);
    try {
      internal.env.PUSH_PAIRING_RETENTION_ENABLED = "0";
      await internal.scheduleAlarm();
      expect(await internal.ctx.storage.getAlarm()).toBe(now + 40 * day);
      internal.env.PUSH_PAIRING_RETENTION_ENABLED = "1";
      await internal.scheduleAlarm();
      expect(await internal.ctx.storage.getAlarm()).toBe(now + 20 * day);
    } finally {
      internal.env.PUSH_PAIRING_RETENTION_ENABLED = "1";
    }
  });
  await stub.forget();
});
