// Lighthouse on every page, mobile and desktop, against a short-lived local server that mimics Pages.
// The pages are built into a temporary folder with SITE_URL pointing at that server, so canonical and
// Open Graph URLs match the origin being tested, exactly as they will in production.
//   bun run lighthouse                       → all pages × mobile + desktop, reports in reports/lighthouse/
//   bun run lighthouse -- --pages home,support --form mobile
//   bun run lighthouse -- --as-is            → test dist/ exactly as built (SITE_URL placeholder)

import { mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { PAGES } from "../src/pages/registry";
import { DIST, ROOT } from "./build";
import { chromePath } from "./chrome";
import { startServer } from "./serve";

const LH = "lighthouse@13.5.0";
const arg = (n: string) => {
  const i = process.argv.indexOf(`--${n}`);
  return i > -1 ? process.argv[i + 1] : undefined;
};
const onlyPages = arg("pages")?.split(",");
const forms = (arg("form") ?? "mobile,desktop").split(",") as ("mobile" | "desktop")[];
const asIs = process.argv.includes("--as-is");
const reportDir = join(ROOT, "reports/lighthouse");
await mkdir(reportDir, { recursive: true });

// Pick a free port, then build with SITE_URL = that origin.
const probe = Bun.serve({ port: 0, fetch: () => new Response("") });
const port = probe.port;
probe.stop(true);
let dir = DIST;
if (!asIs) {
  dir = join(ROOT, ".cache/lighthouse-site");
  await rm(dir, { recursive: true, force: true });
  const b = Bun.spawnSync(["bun", "scripts/build.ts", "--out", dir, "--quiet"], {
    cwd: ROOT,
    env: { ...process.env, SITE_URL: `http://localhost:${port}` },
    stdout: "inherit",
    stderr: "inherit",
  });
  if (b.exitCode !== 0) throw new Error("build for Lighthouse failed");
}
const { server } = await startServer({ dir, port, quiet: true });
const base = `http://localhost:${server.port}`;

type Row = { page: string; form: string; perf: number; a11y: number; bp: number; seo: number; fcp: string; lcp: string; tbt: string; cls: string; si: string; failing: string[] };
const rows: Row[] = [];

try {
  for (const p of PAGES) {
    if (onlyPages && !onlyPages.includes(p.slug)) continue;
    for (const form of forms) {
      const out = join(reportDir, `${p.slug}-${form}.json`);
      const args = [
        "bunx",
        LH,
        base + p.path,
        "--quiet",
        "--output=json",
        `--output-path=${out}`,
        "--only-categories=performance,accessibility,best-practices,seo",
        '--chrome-flags=--headless=new --no-first-run',
        ...(form === "desktop" ? ["--preset=desktop"] : []),
      ];
      // Async spawn: the preview server lives in this process and must keep answering while Lighthouse runs.
      // Lighthouse occasionally fails to record a trace (NO_NAVSTART); retry those runs.
      let code = 1;
      let err = "";
      for (let attempt = 1; attempt <= 3 && code !== 0; attempt++) {
        const proc = Bun.spawn(args, { env: { ...process.env, CHROME_PATH: chromePath() }, stdout: "pipe", stderr: "pipe" });
        code = await proc.exited;
        if (code !== 0) err = await new Response(proc.stderr).text();
      }
      if (code !== 0) {
        console.error(`lighthouse failed for ${p.path} (${form}):\n${err.slice(-2000)}`);
        continue;
      }
      const j = await Bun.file(out).json();
      const score = (k: string) => Math.round((j.categories[k]?.score ?? 0) * 100);
      const dv = (id: string) => j.audits[id]?.displayValue ?? "";
      const failing: string[] = [];
      for (const [cat, c] of Object.entries<any>(j.categories))
        for (const ref of c.auditRefs) {
          const a = j.audits[ref.id];
          if (ref.weight > 0 && a.score !== null && a.score < 1) failing.push(`${cat}:${ref.id}(${a.score})`);
        }
      const row: Row = {
        page: p.slug,
        form,
        perf: score("performance"),
        a11y: score("accessibility"),
        bp: score("best-practices"),
        seo: score("seo"),
        fcp: dv("first-contentful-paint"),
        lcp: dv("largest-contentful-paint"),
        tbt: dv("total-blocking-time"),
        cls: dv("cumulative-layout-shift"),
        si: dv("speed-index"),
        failing,
      };
      rows.push(row);
      console.log(
        `${row.page.padEnd(24)} ${form.padEnd(7)} perf ${row.perf} · a11y ${row.a11y} · bp ${row.bp} · seo ${row.seo} | FCP ${row.fcp} LCP ${row.lcp} TBT ${row.tbt} CLS ${row.cls} SI ${row.si}${failing.length ? `\n    below 1: ${failing.join(", ")}` : ""}`,
      );
    }
  }
} finally {
  server.stop(true);
}

const md = [
  `# Lighthouse ${LH.split("@")[1]} · ${new Date().toISOString().slice(0, 16).replace("T", " ")} UTC`,
  "",
  asIs ? "Tested dist/ as built." : "Tested a build with SITE_URL set to the local test origin (canonical URLs match the served host, as in production).",
  "",
  "| Page | Form | Perf | A11y | Best practices | SEO | FCP | LCP | TBT | CLS | Speed Index |",
  "|---|---|---|---|---|---|---|---|---|---|---|",
  ...rows.map((r) => `| ${r.page} | ${r.form} | ${r.perf} | ${r.a11y} | ${r.bp} | ${r.seo} | ${r.fcp} | ${r.lcp} | ${r.tbt} | ${r.cls} | ${r.si} |`),
  "",
].join("\n");
await Bun.write(join(reportDir, "summary.md"), md);
console.log(`\nsummary → ${join(reportDir, "summary.md")}`);
const low = rows.filter((r) => Math.min(r.perf, r.a11y, r.bp, r.seo) < 95);
if (low.length) {
  console.log(`below 95: ${low.map((r) => `${r.page}/${r.form}`).join(", ")}`);
  process.exitCode = 1;
}
