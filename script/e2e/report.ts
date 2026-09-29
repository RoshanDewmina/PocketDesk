// Builds report.json and report.md for one Farside E2E run directory written by run-e2e.sh.
// Usage: bun script/e2e/report.ts /private/tmp/farside-e2e/reports/<run>
// Exit code: 0 when every scenario passed, was skipped, or failed only a known-issue check; 1 otherwise.
import { existsSync, readdirSync, readFileSync, writeFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

type Json = Record<string, any>;
const runDir = resolve(process.argv[2] ?? "");
if (!process.argv[2] || !existsSync(runDir)) {
  console.error("usage: bun script/e2e/report.ts <run directory>");
  process.exit(2);
}
const repo = resolve(import.meta.dir, "..", "..");

const readJSON = (path: string): Json | undefined => {
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return undefined; }
};
const readLines = (path: string): Json[] => {
  if (!existsSync(path)) return [];
  const out: Json[] = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line.trim().startsWith("{")) continue;
    try { out.push(JSON.parse(line)); } catch { /* partial line */ }
  }
  return out;
};
const tail = <T>(items: T[], count: number) => items.slice(Math.max(0, items.length - count));
const round = (value: unknown, digits = 1) =>
  typeof value === "number" && Number.isFinite(value) ? Math.round(value * 10 ** digits) / 10 ** digits : value;
const inWindow = (entry: Json, start: number, end: number) =>
  typeof entry.t === "number" && entry.t >= start - 1 && entry.t <= end + 1;
const escapeCell = (text: unknown) => String(text ?? "").replace(/\|/g, "\\|").replace(/\n/g, " ");

const meta = readJSON(join(runDir, "meta.json")) ?? {};
const finished = readJSON(join(runDir, "finished.json")) ?? {};
const iterations = readdirSync(runDir)
  .filter((name) => /^iter-\d+$/.test(name))
  .sort((a, b) => Number(a.slice(5)) - Number(b.slice(5)));

type Scenario = {
  iteration: number; id: string; method: string; status: string; reason?: string;
  durationSeconds?: number; exitCode?: number; timedOut?: boolean; failure?: string;
  checks: Json[]; knownIssues: Json[]; metrics: Json; notes: string[];
  excerpts: { xcodebuild: string[]; host: string[]; phone: string[]; testpad: string[] };
};

const scenarios: Scenario[] = [];
const iterationSummaries: Json[] = [];
for (const iterName of iterations) {
  const iteration = Number(iterName.slice(5));
  const iterDir = join(runDir, iterName);
  const logs = join(iterDir, "logs");
  const hostEvents = readLines(join(logs, "host", "events.jsonl"));
  const phoneEvents = readLines(join(logs, "phone", "events.jsonl"));
  const padEvents = readLines(join(logs, "testpad.jsonl"));
  for (const id of readdirSync(iterDir).filter((name) => name !== "logs" && statSync(join(iterDir, name)).isDirectory()).sort()) {
    const dir = join(iterDir, id);
    const harness = readJSON(join(dir, "harness.json")) ?? {};
    const result = readJSON(join(dir, "result.json"));
    const start = harness.startedAt ?? 0, end = harness.finishedAt ?? Number.MAX_SAFE_INTEGER;
    const checks: Json[] = result?.checks ?? [];
    const knownIssues = checks.filter((check) => check.knownIssue && !check.ok);
    let status: string, reason: string | undefined;
    if (harness.setupFailed) { status = "failed"; reason = "harness setup failed before the test started"; }
    else if (harness.timedOut) { status = "failed"; reason = "scenario exceeded its time limit"; }
    else if (!result) { status = harness.exitCode === 0 ? "passed" : "failed"; reason = result ? undefined : "the UI test wrote no result; see xcodebuild.log"; }
    else if (result.status === "passed" && harness.exitCode !== 0) { status = "failed"; reason = `xcodebuild exited ${harness.exitCode}`; }
    else status = result.status;
    if (status === "passed" && knownIssues.length) status = "known-issue";
    const xcodeLog = existsSync(join(dir, "xcodebuild.log")) ? readFileSync(join(dir, "xcodebuild.log"), "utf8").split("\n") : [];
    scenarios.push({
      iteration, id, method: harness.method ?? "", status, reason,
      durationSeconds: harness.finishedAt && harness.startedAt ? harness.finishedAt - harness.startedAt : undefined,
      exitCode: harness.exitCode, timedOut: harness.timedOut, failure: result?.failure, checks, knownIssues,
      metrics: result?.metrics ?? {}, notes: result?.notes ?? [],
      excerpts: {
        xcodebuild: tail(xcodeLog.filter((line) => /error:|E2E CHECK .*(FAIL|KNOWN)|Test Case .*(failed|skipped)|\*\* TEST|Timed out/.test(line)), 25),
        host: tail(hostEvents.filter((e) => inWindow(e, start, end) && e.type !== "stats")
          .map((e) => `${new Date(e.t * 1000).toISOString().slice(11, 19)} ${e.type} ${JSON.stringify(Object.fromEntries(Object.entries(e).filter(([k]) => !["t", "mono", "seq", "role", "run", "pid", "type"].includes(k))))}`), 25),
        phone: tail(phoneEvents.filter((e) => inWindow(e, start, end) && e.type !== "stats")
          .map((e) => `${new Date(e.t * 1000).toISOString().slice(11, 19)} ${e.type} ${e.status ?? e.cmd ?? ""}`), 15),
        testpad: tail(padEvents.filter((e) => inWindow(e, start, end) && !["mouseMoved", "heartbeat", "dragMove", "keyUp", "flagsChanged"].includes(e.type))
          .map((e) => `${new Date(e.t * 1000).toISOString().slice(11, 19)} ${e.type} ${e.element ?? e.phase ?? e.cmd ?? e.event ?? ""}${e.clickCount ? ` x${e.clickCount}` : ""}${e.button && e.button !== "left" ? ` ${e.button}` : ""}`), 20),
      },
    });
  }
  const resources = readLines(join(logs, "resources.jsonl"));
  const byRole: Json = {};
  for (const sample of resources) {
    const role = (byRole[sample.role] ??= { samples: 0, cpuMax: 0, cpuSum: 0, rssMaxMB: 0, rssFirstMB: undefined, rssLastMB: 0 });
    role.samples++; role.cpuSum += sample.cpuPercent ?? 0; role.cpuMax = Math.max(role.cpuMax, sample.cpuPercent ?? 0);
    const rss = (sample.rssKB ?? 0) / 1024;
    role.rssMaxMB = Math.max(role.rssMaxMB, rss); role.rssFirstMB ??= rss; role.rssLastMB = rss;
  }
  for (const role of Object.values(byRole) as Json[]) {
    role.cpuAvg = round(role.cpuSum / Math.max(1, role.samples)); delete role.cpuSum;
    for (const key of ["rssMaxMB", "rssFirstMB", "rssLastMB", "cpuMax"]) role[key] = round(role[key]);
  }
  let streamSummary: string | undefined;
  const statsFiles = [join(logs, "host", "stats.jsonl"), join(logs, "phone", "stats.jsonl")].filter(existsSync);
  const summaryTool = join(repo, "bench", "stats_summary.py");
  if (statsFiles.length && existsSync(summaryTool)) {
    const run = spawnSync("python3", [summaryTool, ...statsFiles], { encoding: "utf8", timeout: 30_000 });
    if (run.status === 0) streamSummary = run.stdout.trim();
  }
  iterationSummaries.push({ iteration, resources: byRole, streamSummary });
}

const counted = (status: string) => scenarios.filter((s) => s.status === status).length;
const byScenario: Json = {};
for (const scenario of scenarios) {
  const entry = (byScenario[scenario.id] ??= { runs: 0, passed: 0, failed: 0, skipped: 0, knownIssue: 0, durations: [] as number[] });
  entry.runs++;
  if (scenario.status === "passed") entry.passed++;
  else if (scenario.status === "failed") entry.failed++;
  else if (scenario.status === "skipped") entry.skipped++;
  else if (scenario.status === "known-issue") entry.knownIssue++;
  if (scenario.durationSeconds) entry.durations.push(scenario.durationSeconds);
}
for (const entry of Object.values(byScenario) as Json[]) {
  const ok = entry.passed + entry.knownIssue;
  entry.flaky = ok > 0 && entry.failed > 0;
  entry.passRate = round(entry.runs ? (ok / Math.max(1, entry.runs - entry.skipped)) * 100 : 0, 0);
  const sorted = [...entry.durations].sort((a: number, b: number) => a - b);
  entry.durationSeconds = sorted.length ? { min: sorted[0], median: sorted[Math.floor(sorted.length / 2)], max: sorted[sorted.length - 1] } : undefined;
  delete entry.durations;
}
const verdict = counted("failed") === 0 ? "pass" : "fail";
const report = {
  ...meta, finishedAt: finished.finishedAt, durationSeconds: finished.finishedAt && meta.startedAt ? finished.finishedAt - meta.startedAt : undefined,
  verdict,
  summary: { total: scenarios.length, passed: counted("passed"), failed: counted("failed"), skipped: counted("skipped"), knownIssue: counted("known-issue"), byScenario },
  iterations: iterationSummaries, scenarios,
};
writeFileSync(join(runDir, "report.json"), JSON.stringify(report, null, 2));

const md: string[] = [];
const when = (epoch?: number) => (epoch ? new Date(epoch * 1000).toISOString().replace("T", " ").slice(0, 19) + "Z" : "?");
md.push(`# Farside E2E report — ${meta.run ?? runDir}`, "");
md.push(`**Verdict: ${verdict.toUpperCase()}** · ${counted("passed")} passed · ${counted("failed")} failed · ${counted("known-issue")} known-issue · ${counted("skipped")} skipped`, "");
md.push(`- Mode: ${meta.mode === "stub" ? "self-test (stub host: no capture, no injection)" : "real host"} · host app: \`${meta.hostApp ?? "?"}\``);
md.push(`- Commit ${meta.commit ?? "?"} · macOS ${meta.macOS ?? "?"} · ${meta.xcode ?? "Xcode ?"} · simulator ${meta.simulator ?? "?"}`);
md.push(`- Started ${when(meta.startedAt)} · finished ${when(finished.finishedAt)} · repeat ${meta.repeat ?? 1} · soak ${meta.soakSeconds ?? "?"} s · Space shortcuts ${meta.spaceKeysEnabled ? "on" : "off"}`, "");
md.push("## Scenarios", "", "| Scenario | Runs | Passed | Failed | Known issue | Skipped | Pass rate | Flaky | Median time |", "|---|---|---|---|---|---|---|---|---|");
for (const [id, e] of Object.entries(byScenario) as [string, Json][]) {
  md.push(`| ${id} | ${e.runs} | ${e.passed} | ${e.failed} | ${e.knownIssue} | ${e.skipped} | ${e.passRate}% | ${e.flaky ? "yes" : "no"} | ${e.durationSeconds ? Math.round(e.durationSeconds.median) + " s" : "–"} |`);
}
md.push("");
for (const summary of iterationSummaries) {
  md.push(`## Iteration ${summary.iteration}`, "", "| Scenario | Status | Time | Checks | Notes |", "|---|---|---|---|---|");
  for (const s of scenarios.filter((x) => x.iteration === summary.iteration)) {
    const passedChecks = s.checks.filter((c) => c.ok).length;
    md.push(`| ${s.id} | ${s.status}${s.reason ? ` (${escapeCell(s.reason)})` : ""} | ${s.durationSeconds ? Math.round(s.durationSeconds) + " s" : "–"} | ${passedChecks}/${s.checks.length} | ${escapeCell(s.notes.slice(0, 2).join("; "))} |`);
  }
  md.push("");
  const roles = Object.entries(summary.resources ?? {}) as [string, Json][];
  if (roles.length) {
    md.push("Process resources (sampled every 5 s by the harness):", "", "| Process | CPU avg % | CPU max % | RSS first → last MB | RSS max MB |", "|---|---|---|---|---|");
    for (const [role, r] of roles) md.push(`| ${role} | ${r.cpuAvg} | ${r.cpuMax} | ${r.rssFirstMB} → ${r.rssLastMB} | ${r.rssMaxMB} |`);
    md.push("");
  }
  if (summary.streamSummary) md.push("Stream stages (bench/stats_summary.py over the E2E host/phone stats):", "", "```", summary.streamSummary, "```", "");
}
const soaks = scenarios.filter((s) => s.id === "f" && s.status !== "skipped");
if (soaks.length) {
  md.push("## Soak", "", "| Iteration | Length | Clicks | Max frame age | Max render gap | Outages | Room boundary survived | Phone / host memory growth |", "|---|---|---|---|---|---|---|---|");
  for (const s of soaks) {
    const m = s.metrics;
    md.push(`| ${s.iteration} | ${round(m.soakSeconds, 0)} s | ${m.clicks ?? "–"} (${(m.clickFailures ?? []).length} missed) | ${round(m.maxFrameAgeMs, 0)} ms | ${round(m.maxRenderGapMs, 0)} ms | ${(m.outages ?? []).length} | ${m.survivedRoomBoundary === undefined ? "not reached" : m.survivedRoomBoundary ? "yes" : "no (known issue)"} | ${round(m.phoneFootprintGrowthMB)} / ${round(m.hostFootprintGrowthMB)} MB |`);
  }
  md.push("");
}
const problems = scenarios.filter((s) => s.status === "failed" || s.status === "known-issue");
if (problems.length) {
  md.push("## Failures and known issues", "");
  for (const s of problems) {
    md.push(`### ${s.id} · iteration ${s.iteration} · ${s.status}`, "");
    if (s.reason) md.push(`Reason: ${s.reason}`, "");
    if (s.failure) md.push("```", s.failure.slice(0, 2000), "```", "");
    const failedChecks = s.checks.filter((c) => !c.ok);
    if (failedChecks.length) md.push(...failedChecks.map((c) => `- ${c.knownIssue ? "Known issue" : "Failed"}: **${c.name}** — ${c.detail}`), "");
    for (const [label, lines] of Object.entries(s.excerpts)) {
      if (lines.length) md.push(`<details><summary>${label} log excerpt</summary>`, "", "```", ...lines, "```", "</details>", "");
    }
  }
}
md.push("## Evidence boundary", "", "Simulator results do not cover haptics, camera QR pairing, true iOS background time, Dynamic Island, cellular/relay routes or physical touch feel. See script/e2e/README.md.", "");
writeFileSync(join(runDir, "report.md"), md.join("\n"));
console.log(`Report written: ${join(runDir, "report.md")} (verdict ${verdict})`);
process.exit(verdict === "pass" ? 0 : 1);
