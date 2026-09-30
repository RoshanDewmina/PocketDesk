import { brotliCompressSync, constants } from "node:zlib";
import { readFileSync, writeFileSync, statSync, mkdirSync } from "node:fs";
const root = import.meta.dir + "/..";
const src = readFileSync(`${root}/src/index.html`, "utf8");
const br = (s: string | Buffer) => brotliCompressSync(Buffer.from(s), { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
const size = (f: string) => statSync(`${root}/site/${f}`).size;
const assets: Record<string, string[]> = {
  a: [],
  a2: [],
  b: ["b/desk.avif", "b/win.avif"],
  c: ["c/poster.avif", "c/reach.mp4"],
};
let html = src;
for (let pass = 0; pass < 2; pass++) {
  const htmlBr = br(html);
  const build: any = {};
  for (const v of ["a", "a2", "b", "c"]) {
    const files: [string, number][] = [["index.html (brotli)", htmlBr], ...assets[v].map((f) => [f, size(f)] as [string, number])];
    files.push(["Doto subset + CSS (Google Fonts, measured 1.2 KB)", 1230]);
    build[v] = { total: files.reduce((s, f) => s + f[1], 0), files };
  }
  html = src.replace("/*__BUILD__*/null", JSON.stringify(build));
  if (pass === 1) { writeFileSync(`${root}/site/index.html`, html); console.log(JSON.stringify(Object.fromEntries(Object.entries(build).map(([k, v]: any) => [k, v.total])))); }
}
writeFileSync(`${root}/site/_headers`, `/*\n  X-Robots-Tag: noindex, nofollow\n  Referrer-Policy: no-referrer\n\n/b/*\n  Cache-Control: public, max-age=3600\n\n/c/*\n  Cache-Control: public, max-age=3600\n`);
writeFileSync(`${root}/site/robots.txt`, "User-agent: *\nDisallow: /\n");
