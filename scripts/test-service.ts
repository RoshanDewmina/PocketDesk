import { createService } from '../Server/src/server';
import type { TurnCredentialProvider } from '../Server/src/turn';

const leaseMs = Number(process.env.POCKETDESK_TEST_LEASE_MS ?? 0);
const relayTTLSeconds = Number(process.env.POCKETDESK_TEST_TURN_TTL_SECONDS ?? 0);
let issued = 0;

const provider: TurnCredentialProvider | undefined = relayTTLSeconds > 0 ? {
  kind: 'coturn',
  ttlSeconds: relayTTLSeconds,
  issue: async ({ role }) => [{
    urls: ['turn:127.0.0.1:9?transport=udp'],
    username: `${role}-${++issued}`,
    credential: 'test-credential',
  }],
} : undefined;

const app = createService({
  port: 0,
  minRenewAfterMs: 250,
  ...(leaseMs > 0 ? { maxRoomLifetimeMs: leaseMs } : {}),
  ...(provider ? { turnProvider: provider, credentialTTLSeconds: relayTTLSeconds, credentialIssuesPerMinute: 600, renewRetryMs: 1000 } : {}),
});
console.log(app.server.port);
process.on('SIGTERM', () => { app.stop(); process.exit(0); });
