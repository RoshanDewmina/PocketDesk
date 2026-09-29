import { openChrome } from "./cdp";
const c = await openChrome();
await c.view(390, 844, 2);
await c.go("http://127.0.0.1:4178/?v=a&chrome=0");
await c.sleep(800);
const ptr = () => c.evalJS(`document.querySelector('.mac-scr .ptr').style.transform`);
const rect = JSON.parse(await c.evalJS(`JSON.stringify(document.querySelector('.ph-scr').getBoundingClientRect())`));
console.log("phone rect", Math.round(rect.x), Math.round(rect.y), Math.round(rect.width), Math.round(rect.height));
// 1) touch drag takes over from the demo
const x0 = rect.x + rect.width * .3, y0 = rect.y + rect.height * .3;
await c.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: x0, y: y0 }] });
const before = await ptr();
for (let i = 1; i <= 12; i++) { await c.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: x0 + i * 8, y: y0 + i * 4 }] }); await c.sleep(16); }
await c.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
await c.sleep(60);
const after = await ptr();
console.log("drag moved pointer:", before !== after, before, "->", after, "ghost opacity:", await c.evalJS(`document.querySelector('.ghost').style.opacity`));
// 2) keyboard: move to dock icon, Enter clicks -> terminal opens and types
await c.evalJS(`document.querySelector('.ph-scr').focus(),1`);
const target = JSON.parse(await c.evalJS(`(()=>{const s=document.querySelector('.mac-scr').getBoundingClientRect(),d=document.querySelector('.mac-scr [data-t=dock]').getBoundingClientRect();return JSON.stringify({x:(d.left+d.width/2-s.left)/s.width,y:(d.top+d.height/2-s.top)/s.height})})()`));
const cur = JSON.parse(await c.evalJS(`(()=>{const s=document.querySelector('.mac-scr').getBoundingClientRect();const m=document.querySelector('.mac-scr .ptr').style.transform.match(/translate3d\\(([-\\d.]+)px, ([-\\d.]+)px/);return JSON.stringify({x:+m[1]/s.width,y:+m[2]/s.height})})()`));
const key = async (k: string, n: number) => { for (let i = 0; i < n; i++) { await c.send("Input.dispatchKeyEvent", { type: "keyDown", key: k, code: k, windowsVirtualKeyCode: { ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40, Enter: 13 }[k] }); await c.send("Input.dispatchKeyEvent", { type: "keyUp", key: k, code: k }); } };
const nx = Math.round((target.x - cur.x) / .025), ny = Math.round((target.y - cur.y) / .025);
await key(nx > 0 ? "ArrowRight" : "ArrowLeft", Math.abs(nx));
await key(ny > 0 ? "ArrowDown" : "ArrowUp", Math.abs(ny));
await key("Enter", 1);
await c.sleep(200);
console.log("terminal open after Enter:", await c.evalJS(`document.querySelector('.mac-scr .scene').classList.contains('term-open')`), "mirror open:", await c.evalJS(`document.querySelector('.ph-desk .scene').classList.contains('term-open')`));
await c.sleep(4200);
console.log("typed:", JSON.stringify(await c.evalJS(`[...document.querySelectorAll('.mac-scr .tl')].map(e=>e.textContent).join(' | ')`)), "check0:", await c.evalJS(`document.querySelector('.mac-scr .ck').classList.contains('on')`));
await c.shot("work/shots/a-interact.png");
// 3) idle 4 s -> demo resumes (ghost visible again)
await c.sleep(4600);
console.log("demo resumed, ghost opacity:", await c.evalJS(`document.querySelector('.ghost').style.opacity`), "term open:", await c.evalJS(`document.querySelector('.mac-scr .scene').classList.contains('term-open')`));
// 4) frame pacing during demo
const pacing = await c.evalJS(`new Promise(r=>{const d=[];let l=0,n=0;function f(t){if(l)d.push(t-l);l=t;if(++n<240)requestAnimationFrame(f);else{d.sort((a,b)=>a-b);r(JSON.stringify({frames:d.length,median:d[d.length>>1].toFixed(2),p95:d[Math.floor(d.length*.95)].toFixed(2),max:d[d.length-1].toFixed(2),over25:d.filter(x=>x>25).length}))}}requestAnimationFrame(f)})`);
console.log("rAF pacing:", pacing);
console.log("logs:", c.logs);
c.close(); process.exit(0);
