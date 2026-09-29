export class Html {
  constructor(readonly value: string) {}
  toString() {
    return this.value;
  }
}

export type Value = Html | string | number | null | undefined | false | Value[];

const ESC: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

export const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ESC[c]!);

export const raw = (s: string) => new Html(s);

function render(v: Value): string {
  if (v === null || v === undefined || v === false) return "";
  if (v instanceof Html) return v.value;
  if (Array.isArray(v)) return v.map(render).join("");
  return esc(String(v));
}

/** Tagged template that escapes every interpolation unless it is already `Html`. */
export function html(strings: TemplateStringsArray, ...values: Value[]): Html {
  let out = strings[0]!;
  for (let i = 0; i < values.length; i++) out += render(values[i]!) + strings[i + 1]!;
  return new Html(out);
}

/** A Doto heading period, set in the UI face because Doto draws "." like a plus. */
export const pd = raw('<span class="pd">.</span>');
