import { openChrome } from "./cdp";
const c = await openChrome();
await c.view(390, 844, 2);
await c.go(`http://127.0.0.1:4178/?v=a2`); await c.sleep(900);
const cam = () => c.evalJS(`document.querySelector('.a2-cam').style.transform`);
const phPtr = () => c.evalJS(`document.querySelector('.ph-scr .ptr').style.transform`);
const r = JSON.parse(await c.evalJS(`JSON.stringify(document.querySelector('.ph-scr').getBoundingClientRect())`));
const x0 = r.x + r.width * .5, y0 = r.y + r.height * .5;
await c.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: x0, y: y0 }] });
await c.sleep(600);
const camA = await cam(), pA = await phPtr();
for (let i = 1; i <= 6; i++) { await c.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: x0 - i * 4, y: y0 }] }); await c.sleep(16); }
await c.sleep(400);
const camB = await cam(), pB = await phPtr();
console.log("phone pointer before/after small move:", pA, "->", pB);
console.log("small move (24 px left) inside the view -> camera unchanged:", camA === camB, camA, camB);
// hold still: no drift
await c.sleep(800); console.log("no drift while idle inside view:", (await cam()) === camB);
// 1:1: pointer on-screen delta equals finger delta when camera does not move
const m = (s: string) => s.match(/translate3d\(([-\d.]+)px, ([-\d.]+)px/)!.slice(1).map(Number);
console.log("pointer moved on phone by", (m(pB)[0] - m(pA)[0]).toFixed(2), "px for a 24 px finger move (1:1 expected)");
await c.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
c.close(); process.exit(0);
