const P = (id, slug, plat, w, h) => ({ id, w, h, plat, out: `posts/${id.replace("post-", "p")}-${slug}-${plat}-${w}x${h}.png` });

export const STILLS = [
  { id: "avatar", w: 1080, h: 1080, out: "avatars/farside-avatar-1080.png", q: { v: "a" } },
  { id: "avatar-b", w: 1080, h: 1080, out: "avatars/farside-avatar-alt-1080.png", q: { v: "b" } },
  { id: "avatar-preview", w: 1200, h: 1740, out: "avatars/farside-avatar-circle-preview.png", after: true },
  { id: "banner-x", w: 1500, h: 500, out: "banners/x-header-1500x500.png" },
  P("post-01", "reach-hero", "ig", 1080, 1350),
  P("post-02", "big-pointer", "ig", 1080, 1080),
  P("post-03", "voice", "ig", 1080, 1350),
  P("post-04", "clipboard", "x", 1600, 900),
  P("post-05", "agent-beta", "x", 1600, 900),
  P("post-06", "zero-accounts", "ig", 1080, 1080),
  P("post-07", "follow-zoom", "x", 1600, 900),
  P("post-08", "last-reached", "ig", 1080, 1080),
  P("post-09", "dialog-2019", "ig", 1080, 1350),
  P("post-10", "built-with-agents", "x", 1080, 1350),
  P("post-11", "free-at-home", "ig", 1080, 1350),
  P("post-12", "dont-walk", "x", 1600, 900),
  P("post-13", "someone-controlling", "x", 1080, 1350),
  P("post-14", "feel-the-click", "ig", 1080, 1080),
  P("post-15", "beta-list", "ig", 1080, 1350),
  { id: "cheat-sheet", w: 1600, h: 2520, out: "copy/brand-cheat-sheet-1600x2520.png", pdf: "copy/brand-cheat-sheet.pdf" },
];
const CAR = { c1: ["c1-iphone-trackpad", 7], c2: ["c2-five-things-couch", 7], c3: ["c3-three-taps", 6] };
for (const [k, [slug, n]] of Object.entries(CAR)) for (let i = 1; i <= n; i++) {
  const id = `${k}-${String(i).padStart(2, "0")}`;
  STILLS.push({ id, w: 1080, h: 1350, out: `carousels/${slug}/${id}-1080x1350.png`, car: k });
}
const VID = (id, slug, dur, cover, extra = {}) => ({ id, page: "videos/video.html", w: 1080, h: 1920, fps: 30, dur, q: { id }, out: `videos/${id}-${slug}-1080x1920.mp4`, cover, coverOut: `videos/${id}-${slug}-cover-1080x1920.png`, ...extra });
const XCUT = (id, slug, dur, cover) => ({ id: `${id}-x`, page: "videos/video.html", w: 1920, h: 1080, fps: 30, dur, q: { id }, out: `videos/x-16x9/${id}-${slug}-x-1920x1080.mp4`, cover, coverOut: `videos/x-16x9/${id}-${slug}-x-cover-1920x1080.png` });
export const VIDEOS = [
  VID("v01", "contact", 10, 0.6),
  VID("v02", "pov-train", 15, 0.5),
  VID("v03", "distance", 10, 0.5),
  VID("v04", "someone-controlling", 12, 0.8),
  VID("v05", "shy-pointer", 12, 0.5),
  VID("v06", "agent-needs-you", 14, 0.7),
  VID("v07", "dictation", 10, 1.8),
  XCUT("v01", "contact", 10, 0.6),
  XCUT("v04", "someone-controlling", 12, 0.8),
];
