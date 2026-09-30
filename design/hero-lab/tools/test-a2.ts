import { openChrome } from "./cdp";
const c = await openChrome();
const base = process.env.BASE || "http://127.0.0.1:4178/";
for (const [w, h, d] of [[390, 844, 2], [375, 667, 2], [1440, 900, 1]] as const) {
  await c.view(w, h, d); c.logs.length = 0;
  await c.go(`${base}?v=a2`);
  await c.evalJS(`new Promise(r=>{window.__cls=0;new PerformanceObserver(l=>{for(const e of l.getEntries())if(!e.hadRecentInput)window.__cls+=e.value}).observe({type:'layout-shift',buffered:true});r(1)})`);
  await c.sleep(1500);
  const info = await c.evalJS(`(()=>{const ph=document.querySelector('.ph-scr').getBoundingClientRect(),st=document.querySelector('.a2-status').getBoundingClientRect(),form=document.querySelector('.join').getBoundingClientRect(),mac=document.querySelector('.mac').getBoundingClientRect();const s=ph.height/188;return JSON.stringify({v:document.documentElement.dataset.v,codePx:+(14*s).toFixed(2),phone:[Math.round(ph.width),Math.round(ph.height)],macTop:Math.round(mac.top),formBottom:Math.round(form.bottom),phoneBottom:Math.round(ph.bottom),statusBottom:Math.round(st.bottom),vh:innerHeight,sw:document.documentElement.scrollWidth,iw:innerWidth,cls:+window.__cls.toFixed(4),weight:document.querySelector('.lab-w span').textContent})})()`);
  console.log(w, h, info, c.logs.length ? "LOGS: " + c.logs.join(" | ") : "no console messages");
}
// interaction at 390
await c.view(390, 844, 2);
await c.go(`${base}?v=a2`); await c.sleep(900);
const cam = () => c.evalJS(`document.querySelector('.a2-cam').style.transform`);
const view = () => c.evalJS(`document.querySelector('.a2-view').style.transform`);
const r = JSON.parse(await c.evalJS(`JSON.stringify(document.querySelector('.ph-scr').getBoundingClientRect())`));
const x0 = r.x + r.width * .2, y0 = r.y + r.height * .5;
await c.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: x0, y: y0 }] });
const cam0 = await cam(), view0 = await view();
const ptr0 = await c.evalJS(`document.querySelector('.mac-scr .ptr').style.transform`);
// small move inside the view: camera must not move
for (let i = 1; i <= 5; i++) { await c.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: x0 + i * 4, y: y0 }] }); await c.sleep(16); }
await c.sleep(300);
const camSmall = await cam();
// long move to the right: pointer hits the edge, camera pans
for (let i = 1; i <= 30; i++) { await c.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: x0 + 20 + i * 7, y: y0 + i * 1.5 }] }); await c.sleep(16); }
const t0 = Date.now(); let settleMs = -1, prev = await cam();
for (let k = 0; k < 40; k++) { await c.sleep(20); const cur = await cam(); if (cur === prev) { settleMs = Date.now() - t0; break; } prev = cur; }
const camBig = await cam(), viewBig = await view();
await c.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
console.log("small move inside view -> camera unchanged:", cam0 === camSmall, "| long move -> camera panned:", cam0 !== camBig, "| ember rect moved:", view0 !== viewBig, "| settled ~", settleMs, "ms after last move (poll granularity ~20-40 ms)");
const macPtr = await c.evalJS(`document.querySelector('.mac-scr .ptr').style.transform`);
console.log("mac pointer moved:", ptr0 !== macPtr, "| ghost hidden while user drives:", await c.evalJS(`document.querySelector('.ghost').style.opacity`));
// keyboard: move pointer into the terminal and tap it
await c.evalJS(`document.querySelector('.ph-scr').focus(),1`);
const kd = async (k: string, n: number) => { for (let i = 0; i < n; i++) { await c.send("Input.dispatchKeyEvent", { type: "keyDown", key: k, code: k, windowsVirtualKeyCode: { ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40, Enter: 13 }[k] }); await c.send("Input.dispatchKeyEvent", { type: "keyUp", key: k, code: k }); } };
const P = JSON.parse(await c.evalJS(`(()=>{const s=document.querySelector('.mac-scr').getBoundingClientRect();const m=document.querySelector('.mac-scr .ptr').style.transform.match(/translate3d\\(([-\\d.]+)px, ([-\\d.]+)px/);return JSON.stringify({x:+m[1]/s.width*800,y:+m[2]/s.height*500})})()`));
const nx = Math.round((606 - P.x) / 24), ny = Math.round((336 - P.y) / 24);
await kd(nx > 0 ? "ArrowRight" : "ArrowLeft", Math.abs(nx)); await kd(ny > 0 ? "ArrowDown" : "ArrowUp", Math.abs(ny));
await kd("Enter", 1); await c.sleep(1100);
console.log("after tap on Terminal: focus =", await c.evalJS(`document.querySelector('.mac-scr .a2-scene').dataset.focus`), "| menu app =", await c.evalJS(`document.querySelector('.mac-scr .app').textContent`), "| prompt shown:", await c.evalJS(`document.querySelector('.ph-scr .s-tt').textContent.includes('[y/n]')`));
await kd("Enter", 1); await c.sleep(700);
console.log("after 2nd tap: committed on phone+mac:", await c.evalJS(`[...document.querySelectorAll('.s-tt')].every(e=>e.textContent.includes('committed'))`), "| hint visible:", await c.evalJS(`document.querySelector('.a2-hint').classList.contains('on')`));
await c.shot("work/shots/a2-interact.png");
await c.sleep(4600);
console.log("idle 4 s -> demo resumed, ghost opacity:", await c.evalJS(`document.querySelector('.ghost').style.opacity`));
const pacing = await c.evalJS(`new Promise(r=>{const d=[];let l=0,n=0;function f(t){if(l)d.push(t-l);l=t;if(++n<300)requestAnimationFrame(f);else{d.sort((a,b)=>a-b);r(JSON.stringify({frames:d.length,median:d[d.length>>1].toFixed(2),p95:d[Math.floor(d.length*.95)].toFixed(2),max:d[d.length-1].toFixed(2),over25:d.filter(x=>x>25).length}))}}requestAnimationFrame(f)})`);
console.log("rAF pacing during auto-demo:", pacing, "| logs:", c.logs);
// reduced motion
await c.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-motion", value: "reduce" }] });
await c.go(`${base}?v=a2&chrome=0`); await c.sleep(1200);
await c.shot("work/shots/rm-a2-390.png");
console.log("RM:", await c.evalJS(`JSON.stringify({try:!!document.querySelector('.try'),focus:document.querySelector('.a2-scene').dataset.focus,committed:document.querySelector('.ph-scr .s-tt').textContent.includes('committed'),anims:document.getAnimations().length})`));
c.close(); process.exit(0);
