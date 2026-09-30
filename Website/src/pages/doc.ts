import { html, raw, type Html } from "../lib/html";
import { breadcrumbNav } from "./layout";

export type Section = { id: string; title: string; body: Html };

/** Page hero for inner pages: caption, Doto heading with one serif accent, lead paragraph. */
export function pageHero(opts: { cap: string; title: Html; lead: Html; extra?: Html; crumbs?: [string, string][] }): Html {
  return html`<section class="page-hero" aria-labelledby="page-title">
  <div class="band-dots htone" aria-hidden="true"></div>
  <div class="w">
    ${opts.crumbs ? breadcrumbNav(opts.crumbs) : ""}
    <p class="cap">${opts.cap}</p>
    <h1 class="h-page dw" id="page-title">${opts.title}</h1>
    <p class="lead">${opts.lead}</p>
    ${opts.extra ?? ""}
  </div>
</section>`;
}

/** Long-form document with a sticky table of contents on wide screens. */
export function docBody(sections: Section[], tocLabel = "On this page"): Html {
  return html`<div class="w doc">
  <details class="toc" data-wide-open>
    <summary class="cap">${tocLabel}</summary>
    <nav aria-label="${tocLabel}"><ol role="list">${sections.map((s) => html`<li><a href="#${s.id}">${s.title}</a></li>`)}</ol></nav>
  </details>
  <div class="prose">
    ${sections.map((s, i) => html`<section class="${i > 1 ? "doc-sec" : ""}" aria-labelledby="${s.id}"><h2 id="${s.id}">${s.title}</h2>\n${s.body}\n</section>`)}
  </div>
</div>`;
}

/** An HTML comment that lists open items for the owner. Never rendered on the page. */
export function ownerComment(title: string, items: string[]): Html {
  const safe = (s: string) => s.replace(/--/g, "–").replace(/<!|>/g, "");
  return raw(`<!--\n  ${safe(title)}\n${items.map((i) => `  - ${safe(i)}`).join("\n")}\n-->`);
}

export const tbc = (text: string) => html`<span class="tbd">${text}</span> <span class="placeholder">(to be confirmed)</span>`;
