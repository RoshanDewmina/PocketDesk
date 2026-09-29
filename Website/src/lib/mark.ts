// The Farside mark: a dot-matrix pointer whose tip is the ember contact dot (design system §1, concept 21).

const ARROW = [
  "#", "##", "###", "####", "#####", "######", "#######", "########", "#########", "##########",
  "######", "##.##", "#...##", "....##", ".....##", ".....##",
];
const ARROW_S = ["#", "##", "###", "####", "#####", "######", "###", "#.##", "...#"];

const BONE = "#EDE8DF";
const INK = "#0A0A0A";
const EMBER = "#FF5B1F";

function dots(rows: string[]) {
  const out: { x: number; y: number; tip: boolean }[] = [];
  rows.forEach((r, y) => {
    for (let x = 0; x < r.length; x++) if (r[x] === "#") out.push({ x: x + 0.5, y: y + 0.5, tip: x === 0 && y === 0 });
  });
  return { list: out, w: Math.max(...rows.map((r) => r.length)), h: rows.length };
}

const circle = (x: number, y: number, r: number) =>
  `M${+(x - r).toFixed(3)} ${y}a${r} ${r} 0 1 0 ${+(2 * r).toFixed(3)} 0a${r} ${r} 0 1 0 ${-(2 * r).toFixed(3)} 0`;

/** Inline SVG of the mark. `size` is the rendered height in CSS px. */
export function markSvg(size: number, opts: { dark?: boolean; className?: string } = {}) {
  const { list, w, h } = dots(size <= 20 ? ARROW_S : ARROW);
  const body = list.filter((d) => !d.tip).map((d) => circle(d.x, d.y, 0.42)).join("");
  const tip = list.find((d) => d.tip)!;
  const width = Math.round((w * size) / h);
  const cls = opts.className ? ` class="${opts.className}"` : "";
  return (
    `<svg${cls} width="${width}" height="${size}" viewBox="0 0 ${w} ${h}" aria-hidden="true" focusable="false">` +
    `<path fill="${opts.dark ? INK : BONE}" d="${body}"/>` +
    `<circle cx="${tip.x}" cy="${tip.y}" r="0.5" fill="${EMBER}"/></svg>`
  );
}

/** Standalone favicon: the small mark on a rounded void plate so it reads on light tab strips too. */
export function faviconSvg() {
  const { list, w, h } = dots(ARROW_S);
  const pad = 2.6;
  const box = h + pad * 2;
  const ox = (box - w) / 2 + 0.4;
  const body = list.filter((d) => !d.tip).map((d) => circle(d.x + ox, d.y + pad, 0.44)).join("");
  const tip = list.find((d) => d.tip)!;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${box} ${box}">` +
    `<rect width="${box}" height="${box}" rx="${(box * 0.22).toFixed(2)}" fill="#050505"/>` +
    `<path fill="${BONE}" d="${body}"/>` +
    `<circle cx="${tip.x + ox}" cy="${tip.y + pad}" r="0.62" fill="${EMBER}"/></svg>`
  );
}
