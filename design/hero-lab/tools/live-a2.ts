import { openChrome } from "./cdp";
const c = await openChrome();
await c.send("Network.enable"); await c.send("Network.setCacheDisabled", { cacheDisabled: true });
for (const [url, w, h, d] of [["https://hero-lab.farside-site-dgk.pages.dev/", 390, 844, 2], ["https://hero-lab.farside-site-dgk.pages.dev/?v=a2", 1440, 900, 1], ["https://hero-lab.farside-site-dgk.pages.dev/?v=a", 390, 844, 2]] as const) {
  await c.view(w, h, d); c.logs.length = 0;
  await c.go(url as string); await c.sleep(3500);
  console.log(url, w, await c.evalJS(`JSON.stringify({v:document.documentElement.dataset.v, weight:document.querySelector('.lab-w span').textContent, rows:[...document.querySelectorAll('#labd tr')].slice(0,4).map(t=>t.textContent.replace(/\\s+/g,' ')), ghost:(document.querySelector('.ghost')||{style:{}}).style.opacity, sw:document.documentElement.scrollWidth})`), c.logs.length ? "LOGS: " + c.logs.join(" | ") : "no console messages");
}
c.close(); process.exit(0);
