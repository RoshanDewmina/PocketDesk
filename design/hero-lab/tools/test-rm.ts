import { openChrome } from "./cdp";
const c = await openChrome();
await c.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-motion", value: "reduce" }] });
for (const v of ["a", "b", "c"]) {
  await c.view(390, 844, 2); c.logs.length = 0;
  await c.go(`http://127.0.0.1:4178/?v=${v}`);
  await c.sleep(1500);
  await c.shot(`work/shots/rm-${v}-390.png`);
  const info = await c.evalJS(`JSON.stringify({video:!!document.querySelector('video'), img:(document.querySelector('.cv img')||{}).currentSrc, anims:document.getAnimations().length, weight:document.querySelector('.lab-w span').textContent})`);
  console.log(v, info, c.logs);
}
// lab details panel open, chrome visible
await c.send("Emulation.setEmulatedMedia", { features: [] });
await c.go(`http://127.0.0.1:4178/?v=c`);
await c.sleep(2500);
await c.evalJS(`document.querySelector('.lab-w').click(),1`);
await c.sleep(200);
await c.shot(`work/shots/lab-c-390.png`);
console.log(await c.evalJS(`document.getElementById('labd').innerText`));
c.close(); process.exit(0);
