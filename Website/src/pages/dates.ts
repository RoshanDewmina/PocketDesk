// When each page's content last changed (ISO dates). Feeds sitemap.xml <lastmod>, the JSON-LD dateModified
// and the visible "Updated" lines, so bump a page's date only when its words change, not on every build.

export const UPDATED: Record<string, string> = {
  "/": "2026-10-05",
  "/about": "2026-10-05",
  "/mac": "2026-10-05",
  "/control-mac-from-iphone": "2026-09-30",
  "/iphone-as-mac-trackpad": "2026-09-30",
  "/remote-desktop-for-mac": "2026-09-30",
  "/blog": "2026-10-05",
  "/blog/before-you-leave-your-mac": "2026-10-05",
  "/blog/ssh-or-remote-desktop-for-ai-agents": "2026-10-05",
  "/compare": "2026-09-28",
  "/support": "2026-10-05",
  "/privacy": "2026-10-05",
  "/terms": "2026-10-05",
};

export function updated(path: string): string {
  const d = UPDATED[path];
  if (!d) throw new Error(`no UPDATED date for ${path} (src/pages/dates.ts)`);
  return d;
}

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

/** "2026-09-30" → "30 September 2026". */
export function longDate(iso: string): string {
  const [y, m, d] = iso.split("-").map(Number);
  return `${d} ${MONTHS[m! - 1]} ${y}`;
}
