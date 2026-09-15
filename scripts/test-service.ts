import { createService } from '../Server/src/server';
const app = createService({port: 0});
console.log(app.server.port);
process.on('SIGTERM', () => { app.stop(); process.exit(0); });
