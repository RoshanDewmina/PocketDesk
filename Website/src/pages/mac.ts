// /mac: the Farside for Mac download. The DMG itself is not in git; scripts/add-mac-download.ts copies it into
// dist/downloads/ after the build and checks it against config.launch (size and SHA-256).

import { config } from "../../site.config";
import { html } from "../lib/html";
import { longDate, updated } from "./dates";
import { pageHero } from "./doc";
import { icon, ogUrl, page, type Assets } from "./layout";
import { breadcrumbs, graph, webPage } from "./schema";

const R = config.requirements;
const PATH = "/mac";
const DESC =
  "Download Farside for Mac, the free helper that lets your iPhone or iPad control your Mac. For Macs with Apple silicon and macOS 26 or later.";

/** Bytes as macOS Finder shows them (decimal megabytes). */
const megabytes = (bytes: number) => `${(bytes / 1_000_000).toFixed(1)} MB`;

export function macPage(assets: Assets) {
  const L = config.launch;
  const crumbs: [string, string][] = [
    ["Home", "/"],
    ["Farside for Mac", PATH],
  ];
  const file = L.macDownloadUrl ? L.macDownloadUrl.split("/").pop()! : null;
  const facts = [L.macVersion ? `Version ${L.macVersion}` : null, L.macBytes ? megabytes(L.macBytes) : null].filter(Boolean).join(" · ");
  const download = L.macDownloadUrl
    ? html`<p class="lead"><a class="cta" href="${L.macDownloadUrl}" download="${file}">Download Farside for Mac<span class="arr" aria-hidden="true">${icon.arrow}</span></a></p>
<p class="lead">Free${facts ? ` · ${facts}` : ""}</p>`
    : html`<p class="lead">Farside for Mac will be a free download from this page <span class="placeholder">(coming soon)</span>.</p>`;

  const body = html`${pageHero({
    crumbs,
    cap: "Farside for Mac",
    title: html`Farside for <em>Mac.</em>`,
    lead: html`The small helper that lets your iPhone or iPad control this Mac. It’s free, and it sits quietly in your menu bar.`,
    extra: download,
  })}
<div class="w doc single">
  <div class="prose">
    <section aria-labelledby="install"><h2 id="install">Install it in three steps</h2>
      <ol class="setup" role="list">
        <li><b>Open the download.</b> Open the file you just downloaded, from your Downloads folder. A window opens with Farside in it.</li>
        <li><b>Drag Farside to Applications.</b> In that window, drag the Farside icon onto the Applications folder.</li>
        <li><b>Open Farside and follow the setup.</b> Open Farside from your Applications folder. Its icon appears in the menu bar at the top of your screen, and a setup window walks you through the two permissions it needs. Then pair your iPhone or iPad; the <a href="/support#setup">support page</a> shows each step.</li>
      </ol>
    </section>
    <section aria-labelledby="needs"><h2 id="needs">What you need</h2>
      <div class="contact-card">
        <dl>
          <div><dt>Your Mac</dt><dd>${R.mac}. Macs with an Intel processor aren’t supported.</dd></div>
          <div><dt>Your iPhone or iPad</dt><dd>An iPhone with ${R.iphone}, or an iPad with ${R.ipad}, with the Farside app.</dd></div>
        </dl>
      </div>
    </section>
    <section aria-labelledby="file"><h2 id="file">About this download</h2>
      <p>Farside for Mac is signed with an Apple Developer ID and checked by Apple (notarized), so your Mac can confirm it comes from us before it opens.</p>
      ${L.macDownloadUrl ? html`<div class="contact-card">
        <dl>
          ${L.macVersion ? html`<div><dt>Version</dt><dd>${L.macVersion}</dd></div>` : ""}
          ${L.macBytes ? html`<div><dt>Size</dt><dd>${megabytes(L.macBytes)}</dd></div>` : ""}
          <div><dt>File</dt><dd>${file}</dd></div>
          ${L.macSha256 ? html`<div><dt>SHA-256 checksum</dt><dd>${L.macSha256}</dd></div>` : ""}
        </dl>
      </div>
      <p>You don’t need the checksum. It’s there if you want to confirm the file arrived unchanged.</p>` : ""}
      <p>Questions? The <a href="/support">support page</a> has help, and a person answers email.</p>
      <p class="meta-row"><span class="cap">Updated · <b>${longDate(updated(PATH))}</b></span></p>
    </section>
  </div>
</div>`;
  return page(
    {
      path: PATH,
      title: "Download Farside for Mac · Farside",
      description: DESC,
      script: "site",
      jsonLd: graph(webPage({ path: PATH, name: "Download Farside for Mac", description: DESC, image: ogUrl(assets, "home"), breadcrumb: true }), breadcrumbs(PATH, crumbs)),
    },
    assets,
    body,
  );
}
