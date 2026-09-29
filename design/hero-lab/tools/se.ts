import { openChrome } from "./cdp";
const c = await openChrome();
await c.view(375, 667, 2);
await c.go("http://127.0.0.1:4178/?v=a2"); await c.sleep(2900);
await c.shot("work/shots/a2-375x667.png");
c.close(); process.exit(0);
