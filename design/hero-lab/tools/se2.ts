import { openChrome } from "./cdp";
const c = await openChrome();
await c.view(375, 667, 2); c.logs.length = 0;
await c.go("http://127.0.0.1:4178/?v=a2"); await c.sleep(1500);
console.log(await c.evalJS(`(()=>{const R=s=>document.querySelector(s).getBoundingClientRect();return JSON.stringify({phoneBottom:Math.round(R('.phone').bottom),statusBottom:Math.round(R('.a2-status span').bottom),vh:innerHeight,overflowX:document.documentElement.scrollWidth>innerWidth})})()`), c.logs);
c.close(); process.exit(0);
