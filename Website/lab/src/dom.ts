type Kid = Node | string;

export function h<K extends keyof HTMLElementTagNameMap>(tag: K, cls = "", kids: Kid[] = []): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (cls) el.className = cls;
  el.append(...kids);
  return el;
}

const NS = "http://www.w3.org/2000/svg";

export function se<K extends keyof SVGElementTagNameMap>(tag: K, attrs: Record<string, string | number> = {}): SVGElementTagNameMap[K] {
  const el = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, String(v));
  return el;
}

export function svg(viewBox: string, cls = "", kids: SVGElement[] = []): SVGSVGElement {
  const s = se("svg", { viewBox, "aria-hidden": "true", focusable: "false" });
  if (cls) s.setAttribute("class", cls);
  s.append(...kids);
  return s;
}

export const use = (id: string) => se("use", { href: `#${id}` });
