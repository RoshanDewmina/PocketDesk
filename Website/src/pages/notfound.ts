import { html } from "../lib/html";
import { icon, page, type Assets } from "./layout";

export function notFoundPage(assets: Assets) {
  const i = assets.img["art-lost"];
  const art = i
    ? html`<img class="lost-art" src="${i.src}" width="${i.w}" height="${i.h}" alt="" decoding="async">`
    : html`<span class="lost-art" aria-hidden="true"></span>`;
  const body = html`<section class="w lost" aria-labelledby="page-title">
  <div>
    <p class="big" aria-hidden="true">404</p>
    <h1 class="h-page" id="page-title">Out of <em>reach.</em></h1>
    <p class="lead">We reached for this page and found nothing there. It may have moved, or the link had a typo. The pointer is probably under a sofa cushion.</p>
    <div class="acts">
      <a class="cta" href="/">Back to the home page <span class="arr">${icon.arrow}</span></a>
      <a class="link" href="/support">Visit support</a>
    </div>
  </div>
  ${art}
</section>`;
  return page(
    {
      path: "/404",
      title: "Page not found · Farside",
      description: "This page is out of reach. Head back to the Farside home page or visit support.",
      script: "site",
      noCanonical: true,
    },
    assets,
    body,
  );
}
