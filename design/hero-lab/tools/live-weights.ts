import { openChrome } from "./cdp";
const c = await openChrome();
for (const v of ["a", "b", "c"]) {
  await c.view(390, 844, 2);
  await c.send("Network.enable"); await c.send("Network.setCacheDisabled", { cacheDisabled: true });
  c.logs.length = 0;
  await c.go(`https://hero-lab.farside-site-dgk.pages.dev/?v=${v}`);
  await c.sleep(v === "c" ? 6000 : 2500);
  const t = await c.evalJS(`[...document.querySelectorAll('#labd tr')].length ? 1 : (document.querySelector('.lab-w').click(), 1)`);
  await c.sleep(150);
  console.log(v, JSON.stringify(await c.evalJS(`document.querySelector('.lab-w span').textContent`)), "\n ", (await c.evalJS(`document.getElementById('labd').innerText`)).split("\n").filter((l: string) => l.trim()).slice(1, 9).join("\n  "), c.logs.length ? "\n  LOGS " + c.logs.join(" | ") : "");
}
c.close(); process.exit(0);
