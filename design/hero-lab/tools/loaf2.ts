import { openChrome } from "./cdp";
const c = await openChrome();
await c.view(390, 844, 2);
await c.go(`http://127.0.0.1:4178/?v=a2`);
await c.sleep(1500);
const r = JSON.parse(await c.evalJS(`JSON.stringify(document.querySelector('.ph-scr').getBoundingClientRect())`));
await c.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: r.x + 100, y: r.y + 60 }] });
for (let i = 1; i <= 20; i++) { await c.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: r.x + 100 + i * 5, y: r.y + 60 }] }); await c.sleep(16); }
await c.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
await c.evalJS(`(()=>{window.__lo=[];window.__jank=[];new PerformanceObserver(l=>{for(const e of l.getEntries())window.__lo.push({t:Math.round(e.startTime),d:Math.round(e.duration),scripts:(e.scripts||[]).map(s=>(s.sourceFunctionName||s.invoker||'')+':'+Math.round(s.duration)+(s.forcedStyleAndLayoutDuration?'/forced'+Math.round(s.forcedStyleAndLayoutDuration):'')).join(' ')})}).observe({type:'long-animation-frame'});let l=0,n=0;function f(t){if(l&&t-l>25)window.__jank.push({at:Math.round(t),gap:Math.round(t-l)});l=t;n++;requestAnimationFrame(f)}requestAnimationFrame(f);window.__n=()=>n;return 1})()`);
await c.sleep(31000);
console.log("frames:", await c.evalJS(`window.__n()`), "jank:", await c.evalJS(`JSON.stringify(window.__jank)`));
console.log("LoAF:", await c.evalJS(`JSON.stringify(window.__lo)`));
c.close(); process.exit(0);
