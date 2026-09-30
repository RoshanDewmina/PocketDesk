import { openChrome } from "./cdp";
const c = await openChrome();
await c.send("Network.enable"); await c.send("Network.setCacheDisabled", { cacheDisabled: true });
for (const [v, w, h] of [["a", 390, 844], ["b", 390, 844], ["c", 390, 844], ["c", 1440, 900]] as const) {
  await c.view(w, h, w < 700 ? 2 : 1); c.logs.length = 0;
  await c.go(`https://hero-lab.farside-site-dgk.pages.dev/?v=${v}`);
  await c.sleep(v === "c" ? 5000 : 2500);
  const r = await c.evalJS(`JSON.stringify({btn:document.querySelector('.lab-w span').textContent, rows:[...document.querySelectorAll('#labd tr')].map(t=>t.textContent.replace(/\\s+/g,' ')), vid:(x=>x?{src:x.currentSrc.slice(0,5),t:+x.currentTime.toFixed(2),paused:x.paused,on:x.classList.contains('on')}:null)(document.querySelector('video')), sw:document.documentElement.scrollWidth})`);
  console.log(v, w, r, c.logs.length ? "LOGS: " + c.logs.join(" | ") : "no console messages");
}
c.close(); process.exit(0);
