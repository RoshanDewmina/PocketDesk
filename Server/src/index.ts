import { loadServiceConfig } from './config';
import { createService } from './server';

const app = createService(loadServiceConfig(process.env));
console.log(`PocketDesk signaling listening on ${app.server.hostname}:${app.server.port}`);
let shuttingDown = false;
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  try { await app.stop(5000); process.exit(0); }
  catch { process.exit(1); }
}
process.on('SIGTERM', () => { void shutdown(); });
process.on('SIGINT', () => { void shutdown(); });
