// Design-preview images rendered from concept 21 (design/farside-round1/21-reach.html) by
// scripts/render-assets.ts. Latency figures in the concept mock-ups are removed before capture.
// Sizes are CSS pixels at 1x; a @2x file sits beside each.

export type Shot = { key: string; selector: string; w: number; h: number; alt: string };

export const SHOTS: Shot[] = [
  {
    key: "phone-home",
    selector: "#devices .dev-slot:nth-of-type(1) .dev",
    w: 320,
    h: 671,
    alt: "Farside Home screen on an iPhone: the paired Studio Mac with its status, and a large Connect button.",
  },
  {
    key: "phone-live",
    selector: "#devices .dev-slot:nth-of-type(2) .dev",
    w: 320,
    h: 671,
    alt: "A live session: the Mac desktop fills the iPhone screen, with a large pointer and an ember dot at its tip.",
  },
  {
    key: "phone-dock",
    selector: "#devices .dev-slot:nth-of-type(3) .dev",
    w: 320,
    h: 671,
    alt: "The controls sheet over a dimmed desktop: Keys, Mic, Clip, Fit and Mode buttons, voice typing listening, and End session.",
  },
  {
    key: "phone-coach",
    selector: "#devices .dev-slot:nth-of-type(4) .dev",
    w: 320,
    h: 671,
    alt: "The gesture coach practice pad: tap anywhere to click the button the pointer is already on.",
  },
  {
    key: "phone-nap",
    selector: "#devices .dev-slot:nth-of-type(5) .dev",
    w: 320,
    h: 671,
    alt: "A friendly error: Your Mac is napping, with one fix and a Try again button.",
  },
  {
    key: "mac-setup",
    selector: "#mac .setup",
    w: 800,
    h: 520,
    alt: "The Mac helper's setup window: two permissions, Screen Recording granted and Accessibility with an Open Settings button.",
  },
  {
    key: "mac-menu",
    selector: "#mac .pop",
    w: 360,
    h: 336,
    alt: "The Mac menu-bar panel while a phone is connected: Allow control, a chime toggle, Pause and Stop Sharing.",
  },
];

export const shot = (key: string) => {
  const s = SHOTS.find((x) => x.key === key);
  if (!s) throw new Error(`unknown shot ${key}`);
  return s;
};

/**
 * Static art drawn once at build time with the same code the concept ran in the browser
 * (src/scripts/art/*), saved as PNG. w/h are the CSS display size.
 */
export type ArtSpec = { key: string; w: number; h: number; ext: "png" | "webp" };

export const ARTS: ArtSpec[] = [
  { key: "art-step1", w: 360, h: 170, ext: "png" },
  { key: "art-step2", w: 360, h: 170, ext: "png" },
  { key: "art-step3", w: 360, h: 170, ext: "png" },
  { key: "art-feat-pad", w: 360, h: 200, ext: "png" },
  { key: "art-feat-zoom", w: 360, h: 200, ext: "png" },
  { key: "art-feat-voice", w: 360, h: 200, ext: "png" },
  { key: "art-feat-trust", w: 360, h: 200, ext: "png" },
  { key: "art-lost", w: 640, h: 400, ext: "webp" },
];


/**
 * Real screenshots of the Farside app (iOS Simulator captures from 29 Sep 2026, ~/Downloads/farside-phone-*.png),
 * encoded to WebP at each width in `widths` as static/img/<key>-<width>.webp. w/h give the aspect ratio.
 */
export type Photo = { key: string; widths: number[]; w: number; h: number; alt: string };

export const PHOTOS: Photo[] = [
  {
    key: "photo-home",
    widths: [320, 640, 900],
    w: 603,
    h: 1311,
    alt: "The Farside Home screen on an iPhone: a paired MacBook Air and a large Connect button.",
  },
];

export const photo = (key: string) => {
  const p = PHOTOS.find((x) => x.key === key);
  if (!p) throw new Error(`unknown photo ${key}`);
  return p;
};
