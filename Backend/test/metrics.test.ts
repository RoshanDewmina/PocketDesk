import { SELF, waitOnExecutionContext, createExecutionContext } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import { incrementDaily, METRIC_EVENTS, purgeMetrics, weeklyMetrics } from "../src/metrics";
import { randomHex } from "../src/util";
import { parseChain, signCompactJws, transactionPayload, type TestChain } from "./helpers/apple-chain";
import { adminHeaders, connectClient, connectHost, open, pairing, postJson, registerMessage, sleep, testEnv } from "./helpers/client";
import { installTurnMock } from "./helpers/turn-mock";

let chain: TestChain;
const enabled = { DB: testEnv.DB, MEASUREMENT_ENABLED: "1" };
const now = Date.parse("2026-10-02T12:00:00Z");
const rows = () => testEnv.DB.prepare("SELECT * FROM daily_metrics ORDER BY day,event").all<{ day: string; event: string; count: number }>();
const total = async (event: string) => (await testEnv.DB.prepare("SELECT SUM(count) AS total FROM daily_metrics WHERE event=?1").bind(event).first<{ total: number | null }>())?.total ?? 0;

beforeAll(() => { chain = parseChain(testEnv.TEST_APPLE_CHAIN); installTurnMock(); });
beforeEach(async () => { await testEnv.DB.prepare("DELETE FROM daily_metrics").run(); });

describe("anonymous daily measurement", () => {
  it("is off unless explicitly enabled, including on the HTTP query", async () => {
    await incrementDaily({ DB: testEnv.DB }, "host_registered", now);
    await incrementDaily({ DB: testEnv.DB, MEASUREMENT_ENABLED: "true" }, "host_registered", now);
    expect((await rows()).results).toEqual([]);
    const ctx = createExecutionContext();
    const response = await worker.fetch(new Request("https://farside.test/v1/admin/metrics/weekly", { headers: adminHeaders() }),
      { ...testEnv, MEASUREMENT_ENABLED: "0" } as Env, ctx);
    await waitOnExecutionContext(ctx);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "measurement_disabled" });
  });

  it("atomically increments concurrent events in UTC buckets without storing identifiers", async () => {
    await Promise.all(Array.from({ length: 24 }, () => incrementDaily(enabled, "host_registered", now)));
    await incrementDaily(enabled, "host_registered", Date.parse("2026-10-03T00:00:00Z"));
    const result = (await rows()).results;
    expect(result).toEqual([
      { day: "2026-10-02", event: "host_registered", count: 24 },
      { day: "2026-10-03", event: "host_registered", count: 1 },
    ]);
    const columns = (await testEnv.DB.prepare("PRAGMA table_info(daily_metrics)").all<{ name: string }>()).results.map(column => column.name);
    expect(columns).toEqual(["day", "event", "count"]);
    for (const row of result) {
      expect(Object.keys(row).sort()).toEqual(["count", "day", "event"]);
      expect(METRIC_EVENTS).toContain(row.event);
      expect(row.day).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    }
    const identifier = randomHex();
    await incrementDaily(enabled, identifier as typeof METRIC_EVENTS[number], now);
    await expect(testEnv.DB.prepare("INSERT INTO daily_metrics VALUES (?1,?2,1)").bind("2026-10-02", identifier).run()).rejects.toThrow();
    expect(JSON.stringify((await rows()).results)).not.toContain(identifier);
  });

  it("never fails an access operation or logs exception details on storage failure", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const db = { prepare: () => { throw new Error("secret-device-and-IP"); } } as unknown as D1Database;
      await expect(incrementDaily({ DB: db, MEASUREMENT_ENABLED: "1" }, "host_registered", now)).resolves.toBeUndefined();
      expect(warning).toHaveBeenCalledExactlyOnceWith('{"event":"measurement_write_failed"}');
    } finally { warning.mockRestore(); }
  });

  it("reports only the complete requested week and leaves unsupported KPIs unknown", async () => {
    for (const [day, event] of [["2026-09-20", "host_registered"], ["2026-09-21", "host_registered"],
      ["2026-09-27", "signaling_ready_free"], ["2026-09-28", "host_registered"]] as const) {
      await incrementDaily(enabled, event, Date.parse(`${day}T12:00:00Z`));
    }
    const before = (await rows()).results;
    const response = await weeklyMetrics(new Request("https://farside.test/v1/admin/metrics/weekly?week=2026-09-21"), enabled, now);
    const text = await response.text();
    expect(response.status).toBe(200);
    expect(text).toContain("| host_registered | 1 |");
    expect(text).toContain("| signaling_ready_free | 1 |");
    expect(text).toContain("| signaling_ready_anywhere | 0 |");
    expect(text).toContain("Working setup / installs | UNKNOWN");
    expect(text).toContain("Week-4 return among working users | UNKNOWN");
    expect((await rows()).results).toEqual(before);
    expect(await (await weeklyMetrics(new Request("https://farside.test/v1/admin/metrics/weekly"), enabled, now)).text()).toBe(text);
  });

  it("rejects partial, invalid, non-Monday, out-of-retention and ambiguous weeks", async () => {
    for (const query of ["week=2026-09-28", "week=2026-09-22", "week=2026-02-30", "week=2026-06-01",
      "week=2027-01-04", "week=nope", "week=2026-09-21&room=secret", "week=2026-09-21&week=2026-09-14"]) {
      expect((await weeklyMetrics(new Request(`https://farside.test/v1/admin/metrics/weekly?${query}`), enabled, now)).status, query).toBe(400);
    }
    const db = { prepare: () => { throw new Error("private data"); } } as unknown as D1Database;
    expect((await weeklyMetrics(new Request("https://farside.test/v1/admin/metrics/weekly"), { DB: db, MEASUREMENT_ENABLED: "1" }, now)).status).toBe(503);
  });

  it("protects the query with the existing bearer and forbids writes", async () => {
    const url = "https://farside.test/v1/admin/metrics/weekly";
    expect((await SELF.fetch(url)).status).toBe(404);
    expect((await SELF.fetch(url, { headers: { authorization: "Bearer nope" } })).status).toBe(404);
    const response = await SELF.fetch(url, { headers: adminHeaders() });
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.text()).not.toContain(testEnv.ADMIN_TOKEN);
    expect((await SELF.fetch(url, { method: "POST", headers: adminHeaders() })).status).toBe(404);
  });

  it("records authenticated free signaling once per admission, excluding rejection and renewal", async () => {
    const p = await pairing();
    const host = await connectHost(p, { features: ["renew.1"] });
    const bad = await open();
    bad.send(registerMessage({ ...p, clientToken: randomHex() }, "client"));
    expect((await bad.next()).type).toBe("error");
    const client = await connectClient(p, { features: ["renew.1"] });
    await host.next(); await client.next();
    client.send({ type: "renew" });
    expect((await client.next()).type).toBe("renewed");
    await expect.poll(() => total("signaling_ready_free")).toBe(1);
    expect(await total("host_registered")).toBe(1);
    expect(await total("signaling_ready_anywhere")).toBe(0);
    const stored = JSON.stringify((await rows()).results);
    for (const identifier of Object.values(p)) expect(stored).not.toContain(identifier);
    client.close(); host.close(); bad.close();
  });

  it("records positive/negative entitlement responses and Anywhere admission without transaction/device keys", async () => {
    const deviceId = randomHex(), transactionId = `measure-${randomHex(6)}`;
    const signedTransaction = await signCompactJws(transactionPayload({ originalTransactionId: transactionId }, Date.now()), chain);
    const verified = await postJson("/v1/entitlements/verify", { signedTransaction, deviceId });
    expect(verified.status).toBe(200);
    const body = await verified.json() as { entitlementToken: string; entitled: boolean };
    expect(body.entitled).toBe(true);
    const rejected = await postJson("/v1/entitlements/verify", { signedTransaction: "bad-signature", deviceId: randomHex() });
    expect(rejected.status).toBe(401);
    const expired = await signCompactJws(transactionPayload({ originalTransactionId: `expired-${randomHex(6)}`, expiresDate: Date.now() - 60_000 }, Date.now()), chain);
    const noAccess = await postJson("/v1/entitlements/verify", { signedTransaction: expired, deviceId: randomHex() });
    expect(noAccess.status).toBe(200);
    expect(await noAccess.json()).toMatchObject({ entitled: false });
    expect((await postJson("/v1/entitlements/verify", {})).status).toBe(400);
    const p = await pairing();
    const host = await connectHost(p);
    const client = await connectClient(p, { entitlement: body.entitlementToken });
    await expect.poll(() => total("signaling_ready_anywhere")).toBe(1);
    await expect.poll(() => total("entitlement_verify_ok")).toBe(1);
    await expect.poll(() => total("entitlement_verify_rejected")).toBe(2);
    await sleep(10);
    expect(await total("signaling_ready_free")).toBe(0);
    const stored = JSON.stringify((await rows()).results);
    for (const identifier of [deviceId, transactionId, signedTransaction, body.entitlementToken, ...Object.values(p)]) expect(stored).not.toContain(identifier);
    client.close(); host.close();
  });

  it("purges days older than the 90-day cutoff without touching current totals", async () => {
    const cutoff = new Date(now - 90 * 86_400_000).toISOString().slice(0, 10);
    await incrementDaily(enabled, "host_registered", now - 91 * 86_400_000);
    await incrementDaily(enabled, "host_registered", now - 90 * 86_400_000);
    await incrementDaily(enabled, "host_registered", now);
    await purgeMetrics(testEnv.DB, now);
    expect((await rows()).results.map(row => row.day)).toEqual([cutoff, "2026-10-02"]);
  });
});
