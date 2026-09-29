import { openChrome } from "./cdp";
const base = process.env.BASE || "http://127.0.0.1:4178/";
const out = process.env.OUT || "work/shots";
const extra = process.env.EXTRA || "&chrome=0";
const only = process.argv.slice(2);
const plan: [string, number, number, number, number][] = [
  ["a", 390, 844, 2, 4300], ["a", 1440, 900, 1, 4300],
  ["b", 390, 844, 2, 3050], ["b", 1440, 900, 1, 3050],
  ["c", 390, 844, 2, 3200], ["c", 1440, 900, 1, 3200],
];
await Bun.$`mkdir -p ${out}`;
const c = await openChrome();
for (const [v, w, h, dpr, delay] of plan) {
  if (only.length && !only.includes(`${v}-${w}`)) continue;
  await c.view(w, h, dpr);
  c.logs.length = 0;
  await c.evalJS(`(()=>{window.__cls=0;try{new PerformanceObserver(l=>{for(const e of l.getEntries())if(!e.hadRecentInput)window.__cls+=e.value}).observe({type:'layout-shift',buffered:true})}catch(e){};return 1})()`).catch(() => 0);
  await c.go(`${base}?v=${v}${extra}`);
  await c.evalJS(`new Promise(r=>{window.__cls=0;new PerformanceObserver(l=>{for(const e of l.getEntries())if(!e.hadRecentInput)window.__cls+=e.value}).observe({type:'layout-shift',buffered:true});r(1)})`);
  await c.evalJS("document.fonts.ready.then(()=>1)");
  await c.sleep(delay);
  await c.shot(`${out}/${v}-${w}.png`);
  const info = await c.evalJS(`JSON.stringify({cls:+window.__cls.toFixed(4), sw:document.documentElement.scrollWidth, iw:innerWidth, sh:document.documentElement.scrollHeight, ih:innerHeight, doto:document.fonts.check('800 16px Doto'), wm:document.querySelector('.wm').scrollWidth, weight:document.querySelector('.lab-w span').textContent, h1:[...document.querySelectorAll('h1')].map(e=>Math.round(e.getBoundingClientRect().height))[0], stage:(r=>[Math.round(r.top),Math.round(r.bottom)])(document.getElementById('stage').getBoundingClientRect()), vid:(v=>v?{t:+v.currentTime.toFixed(2),paused:v.paused,rs:v.readyState}:null)(document.querySelector('video'))})`);
  console.log(v, w, info, c.logs.length ? "\n  LOGS: " + c.logs.join("\n  ") : "");
}
c.close();
process.exit(0);
