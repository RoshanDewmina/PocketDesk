// The hero-lab pages: /lab/hero-variants (all three, tabs) and one full-screen page per variant.
// The Mac scene is A2's markup (src/hero-a2/a2.html), so the variants show the approved desktop.

import a2File from "../src/hero-a2/a2.html" with { type: "text" };

const a2 = a2File as unknown as string;
const i0 = a2.indexOf('<div class="a2-scene">');
const i1 = a2.indexOf('<div class="a2-view">');
if (i0 < 0 || i1 < 0) throw new Error("src/hero-a2/a2.html changed shape: cannot find the Mac scene");
const MAC_SCENE = a2.slice(i0, i1).trim();

const FONTS =
  "https://fonts.googleapis.com/css2?family=Doto:wght@800&family=Geist:wght@400;500;600&family=Geist+Mono:wght@400;500&family=Instrument+Serif:ital@0;1&display=swap";

const SPRITE = `<svg class="lx-sprite" width="0" height="0" aria-hidden="true" focusable="false">
  <symbol id="mk" viewBox="0 0 26 38"><g fill="#EDE8DF"><circle cx="3" cy="8" r="1.4"/><circle cx="7" cy="8" r="1.4"/><circle cx="3" cy="12" r="1.4"/><circle cx="7" cy="12" r="1.4"/><circle cx="11" cy="12" r="1.4"/><circle cx="3" cy="16" r="1.4"/><circle cx="7" cy="16" r="1.4"/><circle cx="11" cy="16" r="1.4"/><circle cx="15" cy="16" r="1.4"/><circle cx="3" cy="20" r="1.4"/><circle cx="7" cy="20" r="1.4"/><circle cx="11" cy="20" r="1.4"/><circle cx="15" cy="20" r="1.4"/><circle cx="19" cy="20" r="1.4"/><circle cx="3" cy="24" r="1.4"/><circle cx="7" cy="24" r="1.4"/><circle cx="11" cy="24" r="1.4"/><circle cx="15" cy="24" r="1.4"/><circle cx="19" cy="24" r="1.4"/><circle cx="23" cy="24" r="1.4"/><circle cx="3" cy="28" r="1.4"/><circle cx="7" cy="28" r="1.4"/><circle cx="11" cy="28" r="1.4"/><circle cx="3" cy="32" r="1.4"/><circle cx="11" cy="32" r="1.4"/><circle cx="15" cy="32" r="1.4"/><circle cx="15" cy="36" r="1.4"/></g><circle cx="3.2" cy="3.2" r="2.8" fill="#FF5B1F"/></symbol>
  <symbol id="ptr" viewBox="-1.5 -1.5 17 23"><path d="M0 0V16.6L4.1 12.8L6.8 19.1L9.7 17.9L7 11.7H12.7Z" fill="#000" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></symbol>
</svg>`;

type V = { id: string; n: number; title: string; line: string; aria: string };

export const VARIANTS: V[] = [
  {
    id: "lid",
    n: 1,
    title: "Lid open",
    line: "The MacBook opens and boots in halftone. The phone rises in portrait, and tapping Connect sends an ember pulse across the gap. Then it pans, pinches in on zsh and types, zooms out, turns to landscape and presses play.",
    aria: "Animated demo: a MacBook opens, an iPhone rises and connects to it, then steers the Mac while an orange outline marks the part of the Mac the phone is showing.",
  },
  {
    id: "pocket",
    n: 2,
    title: "From the pocket",
    line: "Phone first. Farside’s Home screen fills the frame; after Connect the camera pulls back to reveal the Mac as the outline locks on. The phone drags a window across the Mac, pinches in and out, then turns to landscape.",
    aria: "Animated demo: an iPhone shows Farside's Home screen, connects, and the view pulls back to the Mac it now steers, with an orange outline for the region on the phone.",
  },
  {
    id: "orbit",
    n: 3,
    title: "Orbit / split view",
    line: "A slow 3D orbit around the Mac and phone, with the phone’s view large alongside. A dotted link joins the outline to it. Portrait, then landscape, and the pointer pushes past the edge so the view eases after it (D34).",
    aria: "Animated demo: the Mac and iPhone seen in a slow 3D orbit, with the phone's view enlarged beside them and dotted lines linking it to the orange outline on the Mac.",
  },
];

function stage(v: V, fit = false) {
  return `<figure class="lx" data-variant="${v.id}"${fit ? ' data-fit="contain"' : ""} role="img" aria-label="${v.aria}">
  <div class="lx-stage">
    <canvas class="lx-field" aria-hidden="true"></canvas>
    <div class="lx-world">
      <div class="lx-mac" aria-hidden="true">
        <div class="lx-lid">
          <div class="lx-lidf"><div class="lx-scr">
            ${MAC_SCENE}
            <canvas class="lx-boot"></canvas>
            <div class="lx-view"><i></i><i></i><i></i><i></i><b></b><b></b><b></b><b></b></div>
            <div class="lx-mptr"><svg viewBox="-1.5 -1.5 17 23"><use href="#ptr"/></svg></div>
          </div></div>
          <div class="lx-lidb"><svg viewBox="0 0 26 38"><use href="#mk"/></svg></div>
        </div>
        <div class="lx-deck"><i></i></div>
        <div class="lx-base"></div>
      </div>
    </div>
    <svg class="lx-links" aria-hidden="true"></svg>
    <canvas class="lx-fx" aria-hidden="true"></canvas>
    <p class="lx-status"><span><i></i>Your iPhone is steering studio-mac</span></p>
  </div>
</figure>`;
}

function doc(title: string, a: { js: string; css: string }, body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<meta name="color-scheme" content="dark">
<title>${title}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="${FONTS}">
<link rel="stylesheet" href="${a.css}">
<script type="module" src="${a.js}"></script>
</head>
<body class="lab">
${SPRITE}
${body}
</body>
</html>
`;
}

const top = (sub: string) => `<header class="lab-top">
  <a class="lab-mark" href="/lab/hero-variants"><svg viewBox="0 0 26 38" aria-hidden="true"><use href="#mk"/></svg><b>farside</b></a>
  <span>${sub}</span>
</header>`;

export function labPages(a: { js: string; css: string }): Record<string, string> {
  const tabs = [`<button type="button" data-tab="all" aria-selected="true">All three</button>`]
    .concat(VARIANTS.map((v) => `<button type="button" data-tab="${v.id}" aria-selected="false">${v.n} · ${v.title}</button>`))
    .join("");
  const cards = VARIANTS.map(
    (v) => `<article class="card" data-card="${v.id}">
    <div class="card-head"><span class="card-n">${v.n}</span><h2>${v.title}</h2></div>
    <p class="card-line">${v.line}</p>
    ${stage(v)}
    <div class="card-acts"><button type="button" data-replay="${v.id}">Replay</button><a href="/lab/${v.id}">Full screen</a></div>
  </article>`,
  ).join("\n");
  const index = doc(
    "Hero lab · Farside",
    a,
    `${top("Hero lab")}
<main class="lab-main" data-lab data-view="all">
  <div class="lab-intro">
    <h1>Three ways to <em>open</em> the hero.</h1>
    <p>Prototypes for review, built on the approved A2 Mac scene. Each one loops for about 15–20 seconds and pauses when it’s off screen. With Reduce Motion on (or <a href="?still">?still</a>), each shows a still key frame.</p>
  </div>
  <div class="tabs" role="tablist" aria-label="Variants">${tabs}</div>
  <div class="cards">
${cards}
  </div>
</main>`,
  );
  const out: Record<string, string> = { "hero-variants.html": index };
  for (const v of VARIANTS) {
    out[`${v.id}.html`] = doc(
      `${v.n} · ${v.title} · Hero lab`,
      a,
      `${top(`${v.n} · ${v.title}`)}
<main class="solo">
  ${stage(v, true)}
  <nav class="solo-acts"><a href="/lab/hero-variants">All variants</a><button type="button" data-replay="${v.id}">Replay</button></nav>
</main>`,
    );
  }
  return out;
}
