const root = import.meta.dir + "/../site";
const port = +(process.env.PORT || 4178);
Bun.serve({
  port,
  async fetch(req) {
    const u = new URL(req.url);
    let p = decodeURIComponent(u.pathname);
    if (p.endsWith("/")) p += "index.html";
    if (p.includes("..")) return new Response("no", { status: 400 });
    const f = Bun.file(root + p);
    if (!(await f.exists())) return new Response("not found", { status: 404 });
    const range = req.headers.get("range");
    if (range) {
      const m = /bytes=(\d*)-(\d*)/.exec(range)!;
      const size = f.size, start = m[1] ? +m[1] : 0, end = m[2] ? Math.min(+m[2], size - 1) : size - 1;
      return new Response(f.slice(start, end + 1), { status: 206, headers: { "Content-Range": `bytes ${start}-${end}/${size}`, "Accept-Ranges": "bytes", "Content-Type": f.type, "Content-Length": String(end - start + 1) } });
    }
    return new Response(f, { headers: { "Accept-Ranges": "bytes", "Content-Type": f.type } });
  },
});
console.log("serving", root, "on", port);
