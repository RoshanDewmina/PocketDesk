import { json } from "./util";

export const METRIC_EVENTS = [
  "host_registered", "signaling_ready_free", "signaling_ready_anywhere",
  "entitlement_verify_ok", "entitlement_verify_rejected",
] as const;
export type MetricEvent = typeof METRIC_EVENTS[number];
type MetricsEnv = Pick<Env, "DB"> & { MEASUREMENT_ENABLED?: string };
const DAY_MS = 86_400_000;
export const metricsEnabled = (env: MetricsEnv): boolean => env.MEASUREMENT_ENABLED === "1";

/** No caller-provided dimensions; one atomic increment, no per-user deduplication or history. */
export async function incrementDaily(env: MetricsEnv, event: MetricEvent, now = Date.now()): Promise<void> {
  if (!metricsEnabled(env) || !METRIC_EVENTS.includes(event) || !Number.isFinite(now)) return;
  const day = new Date(now).toISOString().slice(0, 10);
  try {
    await env.DB.prepare(
      "INSERT INTO daily_metrics (day,event,count) VALUES (?1,?2,1) ON CONFLICT(day,event) DO UPDATE SET count=count+1",
    ).bind(day, event).run();
  } catch {
    // Never log D1 exceptions (which may contain query details). Measurement must not break access.
    console.warn(JSON.stringify({ event: "measurement_write_failed" }));
  }
}

export async function purgeMetrics(db: D1Database, now: number): Promise<void> {
  const cutoff = new Date(now - 90 * DAY_MS).toISOString().slice(0, 10);
  await db.prepare("DELETE FROM daily_metrics WHERE day < ?1").bind(cutoff).run();
}

/** Caller must authenticate with isAdmin. Reads only aggregate rows, never operational identity tables. */
export async function weeklyMetrics(request: Request, env: MetricsEnv, now = Date.now()): Promise<Response> {
  const url = new URL(request.url);
  const today = new Date(now);
  const monday = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate()) -
    ((today.getUTCDay() + 6) % 7) * DAY_MS;
  const week = url.searchParams.get("week") ?? new Date(monday - 7 * DAY_MS).toISOString().slice(0, 10);
  const start = Date.parse(`${week}T00:00:00Z`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(week) || !Number.isFinite(start) ||
      new Date(start).toISOString().slice(0, 10) !== week || new Date(start).getUTCDay() !== 1 ||
      start + 7 * DAY_MS > monday || start < Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate()) - 90 * DAY_MS ||
      [...url.searchParams.keys()].some(key => key !== "week") || url.searchParams.getAll("week").length > 1) {
    return json({ error: "invalid_week", detail: "Use a Monday UTC within retention, ending before the current week." }, 400);
  }
  if (!metricsEnabled(env)) return json({ error: "measurement_disabled" }, 503);
  const end = new Date(start + 7 * DAY_MS).toISOString().slice(0, 10);
  let rows: Array<{ event: MetricEvent; count: number }>;
  try {
    rows = (await env.DB.prepare(
      "SELECT event,SUM(count) AS count FROM daily_metrics WHERE day >= ?1 AND day < ?2 GROUP BY event",
    ).bind(week, end).all<{ event: MetricEvent; count: number }>()).results;
  } catch {
    return json({ error: "measurement_unavailable" }, 503);
  }
  const totals = new Map(rows.map(row => [row.event, row.count]));
  const lines = [
    `# Farside weekly scorecard: ${week} to ${end} (UTC, end exclusive)`,
    "", "Backend event totals are best effort; zero means no recorded events, not proven no usage.",
    "No unique users, actual media/control success, LAN/relay path, or cohort retention is inferred.",
    "", "| Metric | Value | Target / source |", "| --- | ---: | --- |",
    "| Installs | FILL | ASC Installations (opt-in); First Time Downloads separately |",
    "| Working setup / installs | UNKNOWN | >=70%; picture + control not observed |",
    "| Week-4 return among working users | UNKNOWN | >=30%; use ASC retention proxy separately |",
    "| ASC Day-28 app retention proxy | FILL | Mature opt-in cohort; not working-session retention |",
    "| Active paid Anywhere subscriptions | FILL | 150–200 by end December; ASC subscription report |",
    ...METRIC_EVENTS.map(event => `| ${event} | ${totals.get(event) ?? 0} | Server events; repeats included |`),
    "", "Data coverage: FILL enablement date, interruptions, ASC sample size and reporting lag.",
  ];
  return new Response(lines.join("\n") + "\n", { headers: { "content-type": "text/markdown; charset=utf-8" } });
}
