import { openChrome } from "./cdp";
const c = await openChrome();
await c.view(1250, 918, 2);
await c.go("http://127.0.0.1:4178/_cmp.html");
await c.sleep(500);
await c.shot(process.env.HOME + "/Downloads/farside-hero-lab/hero-lab-compare-390.png");
c.close(); process.exit(0);
