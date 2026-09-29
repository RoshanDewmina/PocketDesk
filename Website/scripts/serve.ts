// Local preview server that behaves like Cloudflare Pages for this site: extensionless routes,
// /page.html → /page redirects, 404.html with a 404 status, _headers, _redirects and gzip.
//   bun run serve               → serves dist/ on http://localhost:4173
//   bun run dev                 → rebuilds on every change in src/ or site.config.ts
//   bun scripts/serve.ts --port 5000 --dir some/folder

import { watch } from "node:fs";
import { stat } from "node:fs/promises";
import { join, normalize } from "node:path";
import { DIST, ROOT } from "./build";

type HeaderRule = { host: string | null; re: RegExp; set: [string, string][]; unset: string[] };
type Redirect = { re: RegExp; to: string; status: number };

const TEXT = /\.(html|css|js|json|svg|xml|txt|webmanifest)$/;

function pattern(path: string) {
  const esc = path.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/:[a-z]+/gi, "[^/]+");
  return new RegExp(`^${esc}$`);
}

async function readHeaders(dir: string): Promise<HeaderRule[]> {
  const f = Bun.file(join(dir, "_headers"));
  if (!(await f.exists())) return [];
  const rules: HeaderRule[] = [];
  let cur: HeaderRule | null = null;
  for (const line of (await f.text()).split("\n")) {
    if (!line.trim() || line.trim().startsWith("#")) continue;
    if (!/^\s/.test(line)) {
      const m = line.trim().match(/^https?:\/\/([^/]+)(\/.*)$/);
      cur = m ? { host: m[1]!, re: pattern(m[2]!), set: [], unset: [] } : { host: null, re: pattern(line.trim()), set: [], unset: [] };
      rules.push(cur);
      continue;
    }
    if (!cur) continue;
    const t = line.trim();
    if (t.startsWith("!")) cur.unset.push(t.slice(1).trim().toLowerCase());
    else {
      const i = t.indexOf(":");
      cur.set.push([t.slice(0, i).trim(), t.slice(i + 1).trim()]);
    }
  }
  return rules;
}

async function readRedirects(dir: string): Promise<Redirect[]> {
  const f = Bun.file(join(dir, "_redirects"));
  if (!(await f.exists())) return [];
  return (await f.text())
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith("#"))
    .map((l) => {
      const [from, to, code] = l.split(/\s+/);
      return { re: pattern(from!), to: to!, status: Number(code ?? 302) };
    });
}

function hostMatches(ruleHost: string, host: string) {
  return pattern(ruleHost).test(host);
}

export async function startServer(opts: { dir?: string; port?: number; quiet?: boolean } = {}) {
  const dir = opts.dir ?? DIST;
  let headerRules = await readHeaders(dir);
  let redirects = await readRedirects(dir);
  const gz = new Map<string, Blob>();

  const reload = async () => {
    headerRules = await readHeaders(dir);
    redirects = await readRedirects(dir);
    gz.clear();
  };

  const isFile = async (p: string) => {
    try {
      return (await stat(p)).isFile();
    } catch {
      return false;
    }
  };

  async function resolve(pathname: string): Promise<{ file: string; status: number } | { redirect: string } | null> {
    let clean: string;
    try {
      clean = normalize(decodeURIComponent(pathname));
    } catch {
      return null;
    }
    if (clean.includes("..") || /\/(_headers|_redirects)$/.test(clean)) return null;
    if (clean.endsWith("/index.html")) return { redirect: clean.slice(0, -"index.html".length) };
    if (clean.endsWith(".html")) return { redirect: clean.slice(0, -".html".length) };
    const candidates = clean.endsWith("/") ? [join(clean, "index.html")] : [clean, `${clean}.html`, join(clean, "index.html")];
    for (const c of candidates) if (await isFile(join(dir, c))) return { file: join(dir, c), status: 200 };
    return null;
  }

  const server = Bun.serve({
    port: opts.port ?? Number(process.env.PORT ?? 4173),
    async fetch(req) {
      const url = new URL(req.url);
      for (const r of redirects) {
        if (r.re.test(url.pathname)) return new Response(null, { status: r.status, headers: { Location: r.to } });
      }
      const hit = await resolve(url.pathname);
      if (hit && "redirect" in hit) return new Response(null, { status: 308, headers: { Location: hit.redirect + url.search } });
      const target = hit ?? { file: join(dir, "404.html"), status: 404 };
      const file = Bun.file(target.file);
      const headers = new Headers({ "Content-Type": file.type });
      for (const rule of headerRules) {
        if (rule.host && !hostMatches(rule.host, url.host)) continue;
        if (!rule.re.test(url.pathname)) continue;
        for (const u of rule.unset) headers.delete(u);
        for (const [k, v] of rule.set) headers.set(k, v);
      }
      let body: Blob = file;
      if (TEXT.test(target.file) && (req.headers.get("accept-encoding") ?? "").includes("gzip")) {
        let z = gz.get(target.file);
        if (!z) gz.set(target.file, (z = new Blob([Bun.gzipSync(new Uint8Array(await file.arrayBuffer()))])));
        body = z;
        headers.set("Content-Encoding", "gzip");
        headers.set("Vary", "Accept-Encoding");
      }
      if (req.method === "HEAD") return new Response(null, { status: target.status, headers });
      return new Response(body, { status: target.status, headers });
    },
  });
  if (!opts.quiet) console.log(`Farside preview → http://localhost:${server.port} (serving ${dir})`);
  return { server, reload };
}

if (import.meta.main) {
  const arg = (name: string) => {
    const i = process.argv.indexOf(`--${name}`);
    return i > -1 ? process.argv[i + 1] : undefined;
  };
  const dir = arg("dir") ?? DIST;
  const port = arg("port") ? Number(arg("port")) : undefined;
  if (process.argv.includes("--watch")) {
    const { build } = await import("./build");
    await build();
    const { reload } = await startServer({ dir, port });
    let timer: Timer | undefined;
    const rebuild = () => {
      clearTimeout(timer);
      timer = setTimeout(async () => {
        try {
          await build({ quiet: true });
          await reload();
          console.log(`rebuilt ${new Date().toLocaleTimeString()}`);
        } catch (e) {
          console.error(e);
        }
      }, 120);
    };
    watch(join(ROOT, "src"), { recursive: true }, rebuild);
    watch(join(ROOT, "site.config.ts"), rebuild);
  } else {
    await startServer({ dir, port });
  }
}
