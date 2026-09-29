// Open Graph cards (1200×630), rendered from the hero art by scripts/render-assets.ts into static/og/.
// Keep lines short: Doto is wide, and link previews are small.

export type OgSpec = { key: string; kicker: string; line1: string; line2: string; accent: string };

export const OG: OgSpec[] = [
  { key: "home", kicker: "Remote control for your own Mac", line1: "Your Mac is far.", line2: "Your reach ", accent: "isn’t." },
  { key: "control-mac-from-iphone", kicker: "Guide · Farside", line1: "Control your Mac", line2: "from your ", accent: "iPhone." },
  { key: "iphone-as-mac-trackpad", kicker: "Guide · Farside", line1: "Your iPhone is", line2: "a Mac ", accent: "trackpad." },
  { key: "remote-desktop-for-mac", kicker: "Guide · Farside", line1: "Remote desktop", line2: "for your ", accent: "Mac." },
  { key: "compare", kicker: "Compared · as of 28 Sep 2026", line1: "Farside and the", line2: "other ", accent: "remotes." },
  { key: "support", kicker: "Support · Farside", line1: "Help is", line2: "", accent: "near." },
];

export const ogFile = (key: string) => `og/og-${key}.png`;
