import { loadSupervisorConfig } from './config';
import { startControlServer } from './controlServer';
import { Supervisor } from './supervisor';

const config = loadSupervisorConfig(process.env);
const supervisor = new Supervisor(config);
const control = startControlServer(config.controlDir, supervisor);

console.log(`pocketdesk codex runtime listening on ${control.socketPath}`);

async function shutdown() {
  control.stop();
  await supervisor.stop();
  process.exit(0);
}

process.on('SIGINT', () => void shutdown());
process.on('SIGTERM', () => void shutdown());
