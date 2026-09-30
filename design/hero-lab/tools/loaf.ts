import { openChrome } from "./cdp";
const c = await openChrome();
await c.view(390, 844, 2);
await c.go(`http://127.0.0.1:4178/?v=a2`);
await c.evalJS(`(()=>{window.__lo=[];window.__jank=[];try{new PerformanceObserver(l=>{for(const e of l.getEntries())window.__lo.push({t:Math.round(e.startTime),d:Math.round(e.duration),blk:Math.round(e.blockingDuration||0),render:Math.round((e.startTime+e.duration)-(e.renderStart||e.startTime)),style:Math.round(e.styleAndLayoutStart?(e.startTime+e.duration-e.styleAndLayoutStart):0),scripts:(e.scripts||[]).map(s=>(s.invoker||'')+':'+Math.round(s.duration)+(s.forcedStyleAndLayoutDuration?'/forced'+Math.round(s.forcedStyleAndLayoutDuration):'')).join(' ')})}).observe({type:'long-animation-frame',buffered:true})}catch(e){window.__lo='unsupported'};let l=0;function f(t){if(l&&t-l>25)window.__jank.push({at:Math.round(t),gap:Math.round(t-l)});l=t;requestAnimationFrame(f)}requestAnimationFrame(f);return 1})()`);
await c.sleep(27000);
console.log("jank frames:", await c.evalJS(`JSON.stringify(window.__jank)`));
console.log("LoAF:", await c.evalJS(`JSON.stringify(window.__lo)`));
c.close(); process.exit(0);
