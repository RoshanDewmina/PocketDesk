import { createBrowserService } from '../Server/src/browser/service';
import { createCloudflareTurnProvider, createCoturnProvider } from '../Server/src/turn';
import type { TurnCredentialProvider } from '../Server/src/turn';
const port = Number(process.env.POCKETDESK_BROWSER_PORT ?? 8788);
if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('Invalid local port');

// Dev keeps devRoutes true (probe/fixtures/diagnostics stay reachable) and TURN
// configuration is optional passthrough of the same env names as production.
const list = (value?: string) => value?.split(',').map(item => item.trim()).filter(Boolean) ?? [];
const credentialTTLSeconds = Number(process.env.TURN_CREDENTIAL_TTL_SECONDS ?? 3600);
const providerTimeoutMs = Number(process.env.TURN_PROVIDER_TIMEOUT_MS ?? 3000);
let turnProvider: TurnCredentialProvider | undefined;
if (process.env.TURN_PROVIDER === 'coturn' && process.env.TURN_SECRET) {
  turnProvider = createCoturnProvider({ urls: list(process.env.TURN_URLS), secret: process.env.TURN_SECRET, ttlSeconds: credentialTTLSeconds });
} else if (process.env.TURN_PROVIDER === 'cloudflare' && process.env.CLOUDFLARE_TURN_KEY_ID && process.env.CLOUDFLARE_TURN_KEY_API_TOKEN) {
  turnProvider = createCloudflareTurnProvider({
    keyId: process.env.CLOUDFLARE_TURN_KEY_ID, apiToken: process.env.CLOUDFLARE_TURN_KEY_API_TOKEN,
    ttlSeconds: credentialTTLSeconds, timeoutMs: providerTimeoutMs,
  });
}
const testForceRelay = process.env.POCKETDESK_BROWSER_TEST_FORCE_RELAY === '1';
if (testForceRelay && !turnProvider) throw new Error('POCKETDESK_BROWSER_TEST_FORCE_RELAY requires a configured TURN_PROVIDER');

const service = createBrowserService({
  port, hostname:'127.0.0.1', origin:process.env.POCKETDESK_BROWSER_ORIGIN, diagnosticsDir:process.env.POCKETDESK_BROWSER_DIAG_DIR,
  devRoutes: true, turnProvider, stunURLs: list(process.env.STUN_URLS), relayTimeoutMs: providerTimeoutMs, testForceRelay,
});
console.log(`PocketDesk private browser service: http://127.0.0.1:${service.port}`);
console.log('Loopback only. No public endpoint, capture, OS input or permissions are started by this service.');
let stopping=false;
async function stop() { if(stopping)return; stopping=true; await service.stop(); process.exit(0); }
process.on('SIGTERM',stop);process.on('SIGINT',stop);
const seconds=Number(process.env.POCKETDESK_BROWSER_DURATION ?? 1800);
if (!Number.isFinite(seconds) || seconds<1 || seconds>7200) { await service.stop(); throw new Error('Duration must be 1–7200 seconds'); }
setTimeout(stop,seconds*1000);
