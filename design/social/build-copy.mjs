import { writeFileSync, mkdirSync, copyFileSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { STILLS, VIDEOS } from "./content.mjs";
import { BIOS, HANDLES, PROFILE, POSTS, CAROUSELS, VIDEOS_COPY, THREAD, CALENDAR, LINK } from "./copy.mjs";

const chars = (s) => [...s].length;
export function xLen(s) {
  const t = s.replace(/https?:\/\/\S+/g, "x".repeat(23));
  let w = 0;
  for (const ch of t) {
    const c = ch.codePointAt(0);
    w += (c <= 4351 || (c >= 8192 && c <= 8205) || (c >= 8208 && c <= 8223) || (c >= 8242 && c <= 8247)) ? 1 : 2;
  }
  return w;
}
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const nl = (s) => esc(s).replace(/\n/g, "<br>");
const quote = (s) => s.split("\n").map((l) => "> " + l).join("\n");
const problems = [];
const check = (ok, msg) => { if (!ok) problems.push(msg); return ok; };

export function buildCopy(OUT, ROOT) {
  const C = join(OUT, "copy"); mkdirSync(C, { recursive: true });
  const stills = Object.fromEntries(STILLS.map((s) => [s.id, s]));
  const vids = Object.fromEntries(VIDEOS.map((v) => [v.id, v]));

  // bios
  let md = `# Farside: bios, handles and profile setup\n\nCounts are computed by script. X bios are also checked with X's weighted count.\n\n`;
  for (const [plat, b] of Object.entries(BIOS)) {
    md += `## ${plat === "x" ? "X" : plat[0].toUpperCase() + plat.slice(1)} (limit ${b.limit})\n\n`;
    if (b.note) md += `${b.note}\n\n`;
    b.items.forEach((t, i) => {
      const n = chars(t), xw = xLen(t);
      check(n <= b.limit && (plat !== "x" || xw <= b.limit), `bio ${plat} ${i + 1} too long (${n})`);
      md += `**Option ${i + 1}** · ${n}/${b.limit} characters${plat === "x" ? ` (weighted ${xw})` : ""}\n\n${quote(t)}\n\n`;
    });
  }
  md += `## Display name\n\n- ${PROFILE.displayName} (first choice)\n- ${PROFILE.displayNameAlt}\n\n## Handles to check (not checked; availability unknown)\n\n| Handle | Works on | Why |\n|---|---|---|\n`;
  HANDLES.forEach((h) => { md += `| \`${h[0]}\` | ${h[1]} | ${h[2]} |\n`; });
  md += `\nX handles allow letters, numbers and underscores only (no dots), 4 to 15 characters. Avoid anything with "the far side". Use one brand tag everywhere: **#farsideapp** (#farside is crowded by the comic).\n\n## Link in bio\n\n${PROFILE.link}\n\n## Pinned posts\n\n`;
  for (const [k, v] of Object.entries(PROFILE.pins)) md += `- **${k === "x" ? "X" : k[0].toUpperCase() + k.slice(1)}:** ${v}\n`;
  md += `\n## Avatar and header\n\n- Avatar (all four platforms, Threads inherits Instagram): \`avatars/farside-avatar-1080.png\`. Alternate: \`avatars/farside-avatar-alt-1080.png\`. Circle-crop check: \`avatars/farside-avatar-circle-preview.png\`.\n- X header: \`banners/x-header-1500x500.png\` (text sits in the middle band; the avatar covers the lower left on the web).\n- Instagram, Threads and TikTok have no banner.\n`;
  writeFileSync(join(C, "bios-and-handles.md"), md);

  // posts
  md = `# Static posts: captions, hashtags, alt text\n\nFirst line of every caption is the hook in plain words (captions are indexed by Instagram search and Google). Hashtags: Instagram 3 to 5, X 0 to 1, Threads one topic tag. Put links in the first reply on X, in the bio elsewhere. Placeholders: \`${LINK}\`.\n\n`;
  for (const [id, p] of Object.entries(POSTS)) {
    const s = stills[id];
    md += `## ${id.replace("post-", "P")} · ${p.title}\n\n![${esc(p.title)}](../${s.out})\n\n- File: \`${s.out}\` (${s.w}×${s.h}) · ${p.plat} · series: ${p.series}\n`;
    if (p.confirm) md += `- **Confirm before posting:** ${p.confirm}\n`;
    if (p.ig) { md += `\n**Instagram caption** (${chars(p.ig)} chars)\n\n${quote(p.ig)}\n\n${p.hashtags.join(" ")}\n`; check(p.hashtags.length <= 5, `${id} too many IG hashtags`); }
    if (p.x) { const w = xLen(p.x); check(w <= 280, `${id} X caption ${w}`); md += `\n**X post** (${w}/280 weighted)\n\n${quote(p.x)}\n`; }
    if (p.threads) { check(chars(p.threads) <= 500, `${id} threads long`); md += `\n**Threads** (${chars(p.threads)}/500) · topic tag: ${p.tag}\n\n${quote(p.threads)}\n`; }
    check(chars(p.alt) <= 100 || !p.ig, `${id} IG alt ${chars(p.alt)} > 100`);
    md += `\n**Alt text** (${chars(p.alt)} chars)\n\n${quote(p.alt)}\n\n---\n\n`;
  }
  writeFileSync(join(C, "posts.md"), md);

  // carousels
  md = `# Carousels (Instagram 1080×1350)\n\nSlide 2 of each is built to work as a second cover: Instagram re-shows carousels to people who scrolled past, often starting from a later slide.\n\n`;
  for (const [k, c] of Object.entries(CAROUSELS)) {
    const slides = STILLS.filter((s) => s.car === k);
    md += `## ${k.toUpperCase()} · ${c.title}\n\nFolder: \`carousels/${c.slug}/\` · ${slides.length} slides\n\n**Caption** (${chars(c.ig)} chars)\n\n${quote(c.ig)}\n\n${c.hashtags.join(" ")}\n\n**Threads** (${chars(c.threads)}/500)\n\n${quote(c.threads)}\n\n| # | File | Alt text (chars) |\n|---|---|---|\n`;
    slides.forEach((s, i) => { const a = c.alt[i] || ""; check(chars(a) <= 100, `${s.id} alt ${chars(a)}`); md += `| ${i + 1} | \`${s.out.split("/").pop()}\` | ${esc(a)} (${chars(a)}) |\n`; });
    md += `\n---\n\n`;
  }
  writeFileSync(join(C, "carousels.md"), md);

  // videos
  md = `# Videos (1080×1920, H.264, 30 fps) and X cuts (1920×1080)\n\nEvery video opens mid-motion with its hook on screen at frame 0 and loops back to that frame. Key text stays inside x 65–960, y 270–1440 (checked on every third frame at render time). Audio tracks are silent: add sound in-app. Business accounts on TikTok and Instagram only get cleared libraries (TikTok Commercial Music Library, Meta Sound Collection), so the notes describe a vibe rather than a song. An original named sound (“farside · the click”) can earn Instagram's audio-reuse signal.\n\n`;
  for (const [id, v] of Object.entries(VIDEOS_COPY)) {
    const f = vids[id], xcut = vids[id + "-x"];
    const mb = existsSync(join(OUT, f.out)) ? (statSync(join(OUT, f.out)).size / 1e6).toFixed(1) + " MB" : "";
    md += `## ${id.toUpperCase()} · ${v.title}\n\n- File: \`${f.out}\` · ${f.dur} s · ${mb}\n- Cover: \`${f.coverOut}\` (frame at ${f.cover} s)\n`;
    if (xcut) md += `- X cut (16:9): \`${xcut.out}\`\n`;
    if (v.confirm) md += `- **Confirm before posting:** ${v.confirm}\n`;
    md += `- Hook at frame 0: **${v.hook}**\n- Beats: ${v.beats}\n\n**TikTok / Reels caption** (${chars(v.caption)} chars)\n\n${quote(v.caption)}\n\nTikTok: ${v.tiktok.join(" ")}  \nInstagram: ${v.ig.join(" ")}\n\n`;
    const w = xLen(v.x); check(w <= 280, `${id} X ${w}`);
    md += `**X post** (${w}/280 weighted)\n\n${quote(v.x)}\n\n**Sound (vibe, no copyrighted audio included):** ${v.sound}\n\n---\n\n`;
  }
  writeFileSync(join(C, "videos.md"), md);

  // calendar
  md = `# 14-day content calendar\n\nDay 1 is tomorrow, Tuesday 29 September 2026. Times are Eastern for a North American audience (Buffer and Sprout 2026 data: X and Threads weekday mornings, Instagram Thu 9 a.m. / Wed noon / 6 p.m., TikTok weekend mornings and weekday afternoons). After week one, move to your own analytics.\n\nCadence: X 2 to 3 posts a day plus a reply block, Threads 1 to 2 a day, Instagram 4 to 5 a week, TikTok 4 to 5 a week. Mix across the two weeks: feature reveals, memes in the brand voice, build-in-public with AI agents, teasers, and beta-list CTAs (roughly one CTA in five posts). Asset IDs: P = static post, C = carousel, V = video (see posts.md, carousels.md, videos.md). \`${LINK}\` = your beta-list link once it exists.\n\n`;
  const count = {};
  CALENDAR.forEach((d) => {
    md += `## Day ${d.d} · ${d.date} · ${d.theme}\n\n| Platform | Time (ET) | What | Type |\n|---|---|---|---|\n`;
    d.items.forEach((it) => { md += `| ${it[0]} | ${it[1]} | ${it[2]} | ${it[3]} |\n`; count[it[3]] = (count[it[3]] || 0) + 1; });
    md += `\n`;
  });
  md += `## Mix check\n\n${Object.entries(count).map(([k, v]) => `- ${k}: ${v}`).join("\n")}\n\n## Rules for the 14 days\n\n- Upload each file natively; never re-post a TikTok download (watermarks make it unoriginal on Instagram and TikTok).\n- Links: X in the first reply, Instagram and TikTok in the bio, Threads in the post is fine.\n- Reply to every comment within the first hour; replies are ranked signals on X and Threads.\n- Don't state a launch date, prices, latency or user numbers; the Anywhere plan is “coming”, agent alerts are “beta”.\n- Two “FILM YOURSELF” slots (days 9 and 13) exist on purpose: real footage of the real app is the one shot nobody can fake.\n`;
  writeFileSync(join(C, "calendar-14-days.md"), md);

  // thread
  md = `# Launch-day X thread (${THREAD.length} posts)\n\nPost on launch day (no date appears in the copy). Media paths are relative to this kit. Links live only in the last post, as the reply that carries them.\n\n`;
  THREAD.forEach((p, i) => { const w = xLen(p.t); check(w <= 280, `thread ${i + 1} ${w}`); md += `### ${i + 1}/${THREAD.length} · ${w}/280 weighted\n\n${quote(p.t)}\n\n${p.media ? `Media: \`${p.media}\`\n\n` : ""}${p.note ? `_${p.note}_\n\n` : ""}`; });
  writeFileSync(join(C, "launch-day-x-thread.md"), md);

  copyFileSync(join(ROOT, "SOCIAL-RESEARCH.md"), join(C, "SOCIAL-RESEARCH.md"));
  writeFileSync(join(OUT, "index.html"), indexHtml(OUT, stills, vids));
  console.log(problems.length ? "COPY PROBLEMS:\n  " + problems.join("\n  ") : "copy: all limits OK");
  return problems;
}

function indexHtml(OUT, stills, vids) {
  const img = (s, cap, w) => `<figure class="it" style="--w:${w || 260}px"><a href="${s.out}"><img loading="lazy" src="${s.out}" alt=""></a><figcaption><b>${esc(cap)}</b><span>${s.w}×${s.h}</span></figcaption></figure>`;
  const posts = Object.entries(POSTS).map(([id, p]) => {
    const s = stills[id];
    return `<article class="card"><a href="${s.out}"><img loading="lazy" src="${s.out}" alt="${esc(p.alt)}"></a><div class="meta"><p class="k">${id.replace("post-", "P")} · ${esc(p.plat)} · ${s.w}×${s.h}</p><h3>${esc(p.title)}</h3>${p.ig ? `<p class="cp">${nl(p.ig)}</p><p class="tags">${p.hashtags.join(" ")}</p>` : `<p class="cp">${nl(p.x)}</p>`}<p class="alt"><b>Alt</b> ${esc(p.alt)}</p></div></article>`;
  }).join("\n");
  const cars = Object.entries(CAROUSELS).map(([k, c]) => {
    const sl = STILLS.filter((s) => s.car === k);
    return `<section class="car"><h3>${k.toUpperCase()} · ${esc(c.title)} <span>${sl.length} slides</span></h3><div class="strip">${sl.map((s, i) => `<a href="${s.out}" title="${esc(c.alt[i] || "")}"><img loading="lazy" src="${s.out}" alt="${esc(c.alt[i] || "")}"></a>`).join("")}</div><p class="cp">${nl(c.ig)}</p><p class="tags">${c.hashtags.join(" ")}</p></section>`;
  }).join("\n");
  const videos = Object.entries(VIDEOS_COPY).map(([id, v]) => {
    const f = vids[id], x = vids[id + "-x"];
    return `<article class="vid"><video src="${f.out}" poster="${f.coverOut}" controls muted loop playsinline preload="metadata"></video><div class="meta"><p class="k">${id.toUpperCase()} · ${f.dur} s · 1080×1920</p><h3>${esc(v.title)}</h3><p class="hook">Hook at frame 0: <b>${esc(v.hook)}</b></p><p class="cp">${nl(v.caption)}</p><p class="tags">${v.tiktok.join(" ")}</p><p class="alt"><b>Sound</b> ${esc(v.sound)}</p>${x ? `<p class="k"><a href="${x.out}">X cut 16:9 → ${x.out.split("/").pop()}</a></p>` : ""}</div></article>`;
  }).join("\n");
  const xcuts = VIDEOS.filter((v) => v.w > v.h).map((v) => `<figure class="xc"><video src="${v.out}" poster="${v.coverOut}" controls muted loop playsinline preload="metadata"></video><figcaption><b>${v.id}</b> 1920×1080 · ${v.dur} s</figcaption></figure>`).join("");
  const bios = Object.entries(BIOS).filter(([, b]) => b.items.length).map(([k, b]) => `<div class="bio"><p class="k">${k === "x" ? "X" : k[0].toUpperCase() + k.slice(1)} · limit ${b.limit}</p>${b.items.map((t) => `<p class="cp">${nl(t)} <span class="n">${chars(t)}</span></p>`).join("")}</div>`).join("");
  const cal = CALENDAR.map((d) => `<tr><td><b>Day ${d.d}</b><br>${d.date}</td><td>${esc(d.theme)}</td><td>${d.items.map((it) => `<span class="pl">${esc(it[0])}</span> ${esc(it[1])} ${esc(it[2])}`).join("<br>")}</td></tr>`).join("");
  const thread = THREAD.map((p, i) => `<li><p class="cp">${nl(p.t)}</p><span class="n">${xLen(p.t)}/280</span></li>`).join("");
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Farside social kit</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Doto:wght@800;900&family=Geist:wght@400;500;600&family=Geist+Mono:wght@500&family=Instrument+Serif:ital@1&display=swap">
<style>
:root{--void:#050505;--panel:#121212;--bone:#EDE8DF;--ash:#8C877F;--dim:#4A4742;--line:rgba(237,232,223,.12);--ember:#FF5B1F}
@media (prefers-color-scheme: light){:root:not([data-theme="dark"]){--void:#050505}}
*{box-sizing:border-box;margin:0}body{background:var(--void);color:var(--bone);font:16px/1.5 Geist,system-ui,sans-serif;-webkit-font-smoothing:antialiased}
a{color:inherit}.w{max-width:1320px;margin:0 auto;padding:0 16px}
header{padding:56px 0 30px;border-bottom:1px solid var(--line)}h1{font:800 clamp(40px,7vw,86px)/1 Doto,monospace}h1 em{font:400 italic 1.1em Instrument Serif,serif}
h2{font:800 clamp(28px,4vw,44px)/1.05 Doto,monospace;margin:56px 0 18px}h3{font:600 20px/1.25 Geist,sans-serif;margin:4px 0 8px}h3 span{font:500 12px 'Geist Mono',monospace;color:var(--ash);letter-spacing:.12em;text-transform:uppercase;margin-left:8px}
.k{font:500 11.5px/1.4 'Geist Mono',monospace;letter-spacing:.12em;text-transform:uppercase;color:var(--ash)}
.lead{color:var(--ash);max-width:820px;margin-top:14px;font-size:17px}.lead b{color:var(--bone);font-weight:500}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:16px}
.card,.vid,.car,.bio,.box{background:var(--panel);border-radius:20px;box-shadow:inset 0 0 0 1px var(--line);overflow:hidden}
.card img{display:block;width:100%;height:auto;background:#000}.meta{padding:14px 16px 18px}
.cp{white-space:normal;color:var(--bone);font-size:14.5px;margin:6px 0}.tags{color:var(--ash);font:500 12.5px 'Geist Mono',monospace}.alt{color:var(--ash);font-size:13.5px;margin-top:8px}.alt b{color:var(--bone);font-weight:500;margin-right:6px}
.row{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start}.it{width:var(--w);max-width:100%}.it img{width:100%;height:auto;border-radius:14px;box-shadow:0 0 0 1px var(--line)}.it figcaption{display:flex;justify-content:space-between;gap:8px;margin-top:8px;font:500 12px 'Geist Mono',monospace;color:var(--ash)}.it figcaption b{color:var(--bone);font-weight:500}
.car{padding:16px;margin-bottom:16px}.strip{display:flex;gap:10px;overflow-x:auto;padding-bottom:8px}.strip img{height:300px;width:auto;border-radius:10px;box-shadow:0 0 0 1px var(--line)}
.vids{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:16px}.vid video{display:block;width:100%;aspect-ratio:9/16;background:#000}.hook{font-size:14px;color:var(--ash)}.hook b{color:var(--bone)}
.xc{flex:1 1 420px;max-width:640px}.xc video{width:100%;aspect-ratio:16/9;background:#000;border-radius:14px}.xc figcaption{font:500 12px 'Geist Mono',monospace;color:var(--ash);margin-top:6px}
.bios{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px}.bio{padding:16px}.n{font:500 11px 'Geist Mono',monospace;color:var(--ash);margin-left:6px}
table{width:100%;border-collapse:collapse;font-size:14px}td{border-top:1px solid var(--line);padding:10px 8px;vertical-align:top}td:first-child{white-space:nowrap;color:var(--ash)}.pl{display:inline-block;min-width:78px;font:500 11px 'Geist Mono',monospace;letter-spacing:.1em;text-transform:uppercase;color:var(--bone)}
ol.th{padding-left:22px}ol.th li{margin:10px 0}.box{padding:16px 18px}.links a{display:inline-block;margin:4px 14px 4px 0;border-bottom:1px solid var(--line)}
footer{margin:64px 0 40px;color:var(--ash);font-size:13px;border-top:1px solid var(--line);padding-top:18px}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;background:var(--ember);box-shadow:0 0 10px var(--ember);margin-right:8px}
</style></head><body><div class="w">
<header><p class="k"><span class="dot"></span>Farside · social launch kit · rendered from code, no AI imagery</p><h1>Your Mac is far<span style="font-family:Geist">.</span> Your reach <em>isn’t.</em></h1>
<p class="lead">Contact sheet for the X, Instagram, Threads and TikTok launch. <b>${STILLS.filter((s) => s.id.startsWith("post")).length} static posts, 3 carousels (${STILLS.filter((s) => s.car).length} slides), ${VIDEOS.filter((v) => v.h > v.w).length} vertical videos + ${VIDEOS.filter((v) => v.w > v.h).length} X cuts</b>, avatars, X header, bios, 14-day calendar, launch-day thread and a one-page cheat sheet. Research first: <a href="copy/SOCIAL-RESEARCH.md">copy/SOCIAL-RESEARCH.md</a>.</p>
<p class="links k" style="margin-top:16px"><a href="copy/bios-and-handles.md">Bios + handles</a><a href="copy/posts.md">Post captions</a><a href="copy/carousels.md">Carousels</a><a href="copy/videos.md">Video captions + sound</a><a href="copy/calendar-14-days.md">14-day calendar</a><a href="copy/launch-day-x-thread.md">Launch-day X thread</a><a href="copy/brand-cheat-sheet.pdf">Cheat sheet (PDF)</a></p></header>
<h2>Avatar and header</h2><div class="row">${img(stills["avatar"], "Avatar · primary", 260)}${img(stills["avatar-b"], "Avatar · alternate", 260)}${img(stills["avatar-preview"], "Circle-crop check", 250)}${img(stills["banner-x"], "X header", 620)}</div>
<h2>Videos</h2><div class="vids">${videos}</div>
<h2>X cuts · 16<span style="font-family:Geist">:</span>9</h2><div class="row">${xcuts}</div>
<h2>Static posts</h2><div class="grid">${posts}</div>
<h2>Carousels</h2>${cars}
<h2>Bios</h2><div class="bios">${bios}</div>
<h2>14-day calendar</h2><div class="box"><table>${cal}</table></div>
<h2>Launch-day X thread</h2><div class="box"><ol class="th">${thread}</ol></div>
<h2>Cheat sheet</h2><div class="row">${img(stills["cheat-sheet"], "Brand for social", 520)}</div>
<footer>Re-render everything: <code>bun design/social/render.ts all</code> from the PocketDesk repo (needs Google Chrome and ffmpeg). Sources live in <code>design/social/</code>. Nothing here has been posted.</footer>
</div></body></html>`;
}
