import { createBrowserService } from './service';
import { createCloudflareTurnProvider, createCoturnProvider } from '../turn';
import type { TurnCredentialProvider } from '../turn';

const env = process.env;
const list = (value?: string) => value?.split(',').map(item => item.trim()).filter(Boolean) ?? [];

function integer(name: string, fallback: number, min: number, max: number) {
  const raw = env[name];
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new Error(`${name} must be an integer from ${min} to ${max}`);
  return value;
}

function requireValue(name: string) {
  const value = env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

const boolFlag = (name: string) => env[name] === '1' || env[name] === 'true';

const port = integer('POCKETDESK_BROWSER_PORT', 8788, 0, 65_535);
const hostname = env.POCKETDESK_BROWSER_BIND ?? '127.0.0.1';
const origin = env.POCKETDESK_BROWSER_ORIGIN;
const diagnosticsDir = env.POCKETDESK_BROWSER_DIAG_DIR;
const mcpPrivateDir = env.POCKETDESK_MCP_PRIVATE_DIR;

// TURN/STUN parsing mirrors ../config.ts (loadServiceConfig) for the native service: same env
// names, same shape. Reused via ../turn.ts rather than re-run through loadServiceConfig, since
// that function also enforces native-only production requirements (ALLOWED_ROOMS, room lifetime)
// that have nothing to do with this browser entrypoint.
const credentialTTLSeconds = integer('TURN_CREDENTIAL_TTL_SECONDS', 3600, 60, 86_400);
const providerTimeoutMs = integer('TURN_PROVIDER_TIMEOUT_MS', 3000, 250, 10_000);

const stunURLs = list(env.STUN_URLS);
if (stunURLs.length > 8 || stunURLs.some(url => !/^(?:stun|stuns):[^\s]{1,500}$/.test(url))) {
  throw new Error('STUN_URLS must contain at most 8 valid STUN URLs');
}

const providerName = env.TURN_PROVIDER;
let turnProvider: TurnCredentialProvider | undefined;
if (providerName === 'coturn') {
  turnProvider = createCoturnProvider({
    urls: list(env.TURN_URLS),
    secret: requireValue('TURN_SECRET'),
    ttlSeconds: credentialTTLSeconds,
  });
} else if (providerName === 'cloudflare') {
  turnProvider = createCloudflareTurnProvider({
    keyId: requireValue('CLOUDFLARE_TURN_KEY_ID'),
    apiToken: requireValue('CLOUDFLARE_TURN_KEY_API_TOKEN'),
    ttlSeconds: credentialTTLSeconds,
    timeoutMs: providerTimeoutMs,
  });
} else if (providerName) {
  throw new Error('TURN_PROVIDER must be coturn or cloudflare');
}

const testForceRelay = boolFlag('POCKETDESK_BROWSER_TEST_FORCE_RELAY');
if (testForceRelay && !turnProvider) {
  throw new Error('POCKETDESK_BROWSER_TEST_FORCE_RELAY requires TURN_PROVIDER=coturn or TURN_PROVIDER=cloudflare');
}

const service = createBrowserService({
  port,
  hostname,
  origin,
  mcpPrivateDir,
  diagnosticsDir,
  devRoutes: false,
  turnProvider,
  stunURLs,
  relayTimeoutMs: providerTimeoutMs,
  testForceRelay,
});

console.log(`PocketDesk browser service listening on ${hostname}:${service.port}`);
console.log('Production routes only. /probe, /fixtures and /api/diagnostics are not served.');

let shuttingDown = false;
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  try { await service.stop(); process.exit(0); }
  catch { process.exit(1); }
}
process.on('SIGTERM', () => { void shutdown(); });
process.on('SIGINT', () => { void shutdown(); });
