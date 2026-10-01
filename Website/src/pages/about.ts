import { config } from "../../site.config";
import { html } from "../lib/html";
import { longDate, updated } from "./dates";
import { pageHero } from "./doc";
import { ctaSentence, email, ogUrl, page, type Assets } from "./layout";
import { graph, webPage } from "./schema";

const PATH = "/about";
const DESC = "Who makes Farside, what it is and how to reach us. Farside lets you use your own Mac from your iPhone. Free on the same Wi‑Fi.";

export function aboutPage(assets: Assets) {
  const image = ogUrl(assets, "home");
  const body = html`${pageHero({
    cap: "About",
    title: html`About <em>Farside.</em>`,
    lead: html`Farside lets you use your own Mac from your iPhone. Your Mac’s screen shows on your phone, and the whole phone screen becomes its trackpad.`,
  })}
<div class="w doc single">
  <div class="prose">
    <section aria-labelledby="what"><h2 id="what">What it is</h2>
      <p>Farside has two parts. Farside for Mac runs on your Mac and is free. Farside for iPhone is the app you hold.</p>
      <p>On the same Wi‑Fi it’s free, with no account and no ads. Farside Anywhere, a paid plan for reaching your Mac from somewhere else, is coming after launch.</p>
    </section>
    <section aria-labelledby="who"><h2 id="who">Who makes it</h2>
      <p>${config.contact.legalName ? html`Farside is made by ${config.contact.legalName}, an independent developer in Canada.` : html`Farside is made by an independent developer in Canada.`}</p>
      <p>Farside at getfarside.com isn’t related to farside.app or to other products with a similar name.</p>
    </section>
    <section aria-labelledby="now"><h2 id="now">Where it stands</h2>
      <p>Farside is heading into a TestFlight beta, with the App Store to follow. ${ctaSentence()}</p>
    </section>
    <section aria-labelledby="contact"><h2 id="contact">Contact</h2>
      <p>Email ${email("support")}. We reply ${config.contact.responseTime ?? "as soon as we can"}. The <a href="/support">support page</a> has setup help and answers.</p>
      <p class="meta-row"><span class="cap">Updated · <b>${longDate(updated(PATH))}</b></span></p>
    </section>
  </div>
</div>`;
  return page(
    {
      path: PATH,
      title: "About Farside · Remote desktop for your Mac",
      description: DESC,
      script: "site",
      jsonLd: graph(webPage({ path: PATH, name: "About Farside", description: DESC, image, type: "AboutPage" })),
    },
    assets,
    body,
  );
}
