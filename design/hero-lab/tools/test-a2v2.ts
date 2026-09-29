import { openChrome } from "./cdp";
const c = await openChrome();
const base = process.env.BASE || "http://127.0.0.1:4178/";
for (const [w, h, d, chrome] of [[390, 844, 2, ""], [390, 844, 2, "&chrome=0"], [375, 667, 2, ""], [1440, 900, 1, ""]] as const) {
  await c.view(w, h, d); c.logs.length = 0;
  await c.go(`${base}?v=a2${chrome}`);
  await c.evalJS(`new Promise(r=>{window.__cls=0;new PerformanceObserver(l=>{for(const e of l.getEntries())if(!e.hadRecentInput)window.__cls+=e.value}).observe({type:'layout-shift',buffered:true});r(1)})`);
  await c.sleep(3000);
  console.log(w, h, chrome || "(lab bar)", await c.evalJS(`(()=>{const R=s=>document.querySelector(s).getBoundingClientRect(),ph=R('.ph-scr'),s=ph.height/188;return JSON.stringify({textPx:+(14*s).toFixed(1),h1Bottom:Math.round(R('h1').bottom),joinBottom:Math.round(R('.join').bottom),macTop:Math.round(R('.mac').top),phoneBottom:Math.round(R('.phone').bottom),vh:innerHeight,overflowX:document.documentElement.scrollWidth>innerWidth,cls:+window.__cls.toFixed(4),numbersInStatus:/\\d/.test(document.querySelector('.a2-status').textContent)})})()`), c.logs.length ? "LOGS: " + c.logs.join(" | ") : "no console messages");
}
await c.view(390, 844, 2);
await c.go(`${base}?v=a2`); await c.sleep(2600);
console.log("keyboard up during demo:", await c.evalJS(`document.querySelector('.kb').style.transform`), "| Mac field text:", JSON.stringify(await c.evalJS(`document.querySelector('.mac-scr .ch-in .tx').textContent`)), "| phone copy:", JSON.stringify(await c.evalJS(`document.querySelector('.ph-scr .ch-in .tx').textContent`)));
const cam = () => c.evalJS(`document.querySelector('.a2-cam').style.transform`);
const ptr = () => c.evalJS(`document.querySelector('.ph-scr .ptr').style.transform`);
const r = JSON.parse(await c.evalJS(`JSON.stringify(document.querySelector('.ph-scr').getBoundingClientRect())`));
const x0 = r.x + r.width * .5, y0 = r.y + r.height * .5;
await c.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: x0, y: y0 }] });
await c.sleep(700);
console.log("takeover: keyboard slid away:", await c.evalJS(`document.querySelector('.kb').style.transform`), "| ghost:", await c.evalJS(`document.querySelector('.ghost').style.opacity`));
const camA = await cam(), pA = await ptr();
for (let i = 1; i <= 6; i++) { await c.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: x0 - i * 4, y: y0 }] }); await c.sleep(16); }
await c.sleep(400);
const m = (s: string) => s.match(/translate3d\(([-\d.]+)px, ([-\d.]+)px/)!.slice(1).map(Number);
console.log("1:1 pointer:", (m(await ptr())[0] - m(pA)[0]).toFixed(2), "px for -24 px | camera still inside dead zone:", camA === await cam());
await c.sleep(800); console.log("no drift:", camA === await cam());
for (let i = 1; i <= 40; i++) { await c.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: x0 - 24 + i * 6, y: y0 - i * 1.5 }] }); await c.sleep(16); }
const t0 = Date.now(); let prev = await cam(), settle = -1;
for (let k = 0; k < 40; k++) { await c.sleep(20); const cur = await cam(); if (cur === prev) { settle = Date.now() - t0; break; } prev = cur; }
console.log("edge move panned camera:", camA !== await cam(), "| settled within ~", settle, "ms after the finger stopped");
await c.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
await c.sleep(4700);
console.log("idle 4 s -> demo resumed, ghost opacity:", await c.evalJS(`document.querySelector('.ghost').style.opacity`));
const pacing = await c.evalJS(`new Promise(r=>{const d=[];let l=0,n=0;function f(t){if(l)d.push(t-l);l=t;if(++n<600)requestAnimationFrame(f);else{d.sort((a,b)=>a-b);r(JSON.stringify({frames:d.length,median:d[d.length>>1].toFixed(2),p95:d[Math.floor(d.length*.95)].toFixed(2),max:d[d.length-1].toFixed(2),over25:d.filter(x=>x>25).length}))}}requestAnimationFrame(f)})`);
console.log("rAF pacing over 10 s of auto-demo:", pacing, "| logs:", c.logs);
await c.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-motion", value: "reduce" }] });
await c.go(`${base}?v=a2&chrome=0`); await c.sleep(1200);
await c.shot("work/shots/rm-a2v2-390.png");
console.log("RM:", await c.evalJS(`JSON.stringify({try:!!document.querySelector('.try'),kb:document.querySelector('.kb').style.transform,text:document.querySelector('.ph-scr .ch-in .tx').textContent,anims:document.getAnimations().length})`));
c.close(); process.exit(0);
