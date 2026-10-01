import { config } from "../../site.config";
import { html } from "../lib/html";
import { pageHero } from "./doc";
import { page, type Assets } from "./layout";

function liveStatusUrl(): string | null {
  try { const url = new URL(config.serviceStatus.liveUrl ?? "");
    return url.protocol === "https:" && !url.username && !url.password ? url.href : null;
  } catch { return null; }
}

export function statusPage(assets: Assets): string {
  const live = liveStatusUrl();
  const body = html`${pageHero({ cap: "Service status", title: html`Connection <em>updates.</em>`,
    lead: html`Check service availability and find help when a connection fails.` })}
  <div class="w doc single"><div class="prose">
    <h2>Current availability</h2>
    ${live ? html`<p><a href="${live}" rel="noopener">Open the live service status page</a> for current updates.</p>`
      : html`<p>Live service status is not available here yet. Signalling, relay and notification availability are unverified; this page does not report that they are working.</p>`}
    <h2>If your Mac won’t connect</h2>
    <p>A service update cannot tell whether your Mac is awake, unlocked, online or sharing. In Farside, use <b>Test connection to my Mac</b> to check your own authorized path, then follow the <a href="/support#cant-connect">connection checklist</a>.</p>
    <p>Already paired local access can work independently of the internet service when both devices are on your own network. Remote access and notifications have separate service requirements.</p>
    <p><a href="/support#contact">Contact support</a> with the message you see and a redacted diagnostic report. Keep pairing codes, passwords and screen contents private.</p>
  </div></div>`;
  return page({ path: "/status", title: "Service status · Farside", description: "Service availability updates and help for a failed Farside connection.", script: "site" }, assets, body);
}
