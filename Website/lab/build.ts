// Builds the site plus the hero-lab pages (/lab/*) into one folder for a Cloudflare Pages branch preview.
// The production build (scripts/build.ts, dist/) is untouched.
//   bun lab/build.ts                 → dist-lab/
//   bun lab/build.ts --out <dir>

import { mkdir, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";
import { build, ROOT } from "../scripts/build";
import { labPages } from "./pages";

const i = process.argv.indexOf("--out");
const out = i > -1 ? process.argv[i + 1]! : join(ROOT, "dist-lab");

await build({ outDir: out, quiet: true });
const dir = join(out, "lab");
await mkdir(dir, { recursive: true });

const js = await Bun.build({
  entrypoints: [join(ROOT, "lab/src/main.ts")],
  outdir: dir,
  naming: "lab-[hash].[ext]",
  target: "browser",
  format: "esm",
  minify: true,
});
if (!js.success) throw new AggregateError(js.logs, "lab JavaScript bundle failed");
const css = await Bun.build({ entrypoints: [join(ROOT, "lab/lab.css")], outdir: dir, naming: "lab-[hash].[ext]", minify: true });
if (!css.success) throw new AggregateError(css.logs, "lab CSS bundle failed");

const jsFile = basename(js.outputs.find((o) => o.kind === "entry-point")!.path);
const cssFile = basename(css.outputs.find((o) => o.path.endsWith(".css"))!.path);
const pages = labPages({ js: `/lab/${jsFile}`, css: `/lab/${cssFile}` });
await Promise.all(Object.entries(pages).map(([name, body]) => writeFile(join(dir, name), body)));
console.log(`site + hero lab → ${out}  (lab: ${Object.keys(pages).join(", ")}, ${jsFile}, ${cssFile})`);
