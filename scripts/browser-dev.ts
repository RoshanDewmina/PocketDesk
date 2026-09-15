import { createBrowserService } from '../Server/src/browser/service';
const port = Number(process.env.POCKETDESK_BROWSER_PORT ?? 8788);
if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('Invalid local port');
const service = createBrowserService({ port, hostname:'127.0.0.1', origin:process.env.POCKETDESK_BROWSER_ORIGIN, diagnosticsDir:process.env.POCKETDESK_BROWSER_DIAG_DIR });
console.log(`PocketDesk private browser service: http://127.0.0.1:${service.port}`);
console.log('Loopback only. No public endpoint, capture, OS input or permissions are started by this service.');
let stopping=false;
async function stop() { if(stopping)return; stopping=true; await service.stop(); process.exit(0); }
process.on('SIGTERM',stop);process.on('SIGINT',stop);
const seconds=Number(process.env.POCKETDESK_BROWSER_DURATION ?? 1800);
if (!Number.isFinite(seconds) || seconds<1 || seconds>7200) { await service.stop(); throw new Error('Duration must be 1–7200 seconds'); }
setTimeout(stop,seconds*1000);
