import { createCloudflareTurnProvider, createCoturnProvider } from './turn';
import type { ServiceConfig } from './server';
import { createFileRoomApproval } from './rooms';

const token = /^[a-f0-9]{64}$/;
const list = (value?: string) => value?.split(',').map(item => item.trim()).filter(Boolean) ?? [];

function integer(env: Record<string, string | undefined>, name: string, fallback: number, min: number, max: number) {
  const raw = env[name];
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new Error(`${name} must be an integer from ${min} to ${max}`);
  return value;
}

function requireValue(env: Record<string, string | undefined>, name: string) {
  const value = env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function flag(env: Record<string, string | undefined>, name: string) {
  const raw = env[name];
  if (raw === undefined) return false;
  if (raw === '1' || raw === 'true') return true;
  if (raw === '0' || raw === 'false') return false;
  throw new Error(`${name} must be 0, 1, true, or false`);
}

export function loadServiceConfig(
  env: Record<string, string | undefined>,
  options: { fetch?: typeof globalThis.fetch } = {},
): ServiceConfig {
  const production = env.NODE_ENV === 'production';
  const port = integer(env, 'PORT', 8787, 1, 65_535);
  const credentialTTLSeconds = integer(env, 'TURN_CREDENTIAL_TTL_SECONDS', 3600, 60, 86_400);
  const providerTimeoutMs = integer(env, 'TURN_PROVIDER_TIMEOUT_MS', 3000, 250, 10_000);
  const authTimeoutMs = integer(env, 'AUTH_TIMEOUT_MS', 5000, 1000, 30_000);
  const approvalAuditMs = integer(env, 'APPROVAL_AUDIT_INTERVAL_MS', 1000, 100, 5000);
  const roomLifetimeSeconds = integer(env, 'ROOM_LIFETIME_SECONDS', 1800, 60, 86_400);
  if (providerTimeoutMs >= authTimeoutMs) throw new Error('TURN_PROVIDER_TIMEOUT_MS must be lower than AUTH_TIMEOUT_MS');
  if (roomLifetimeSeconds >= credentialTTLSeconds) {
    throw new Error('ROOM_LIFETIME_SECONDS must be lower than TURN_CREDENTIAL_TTL_SECONDS');
  }
  const allowedRooms = list(env.ALLOWED_ROOMS);
  if (allowedRooms.some(room => !token.test(room)) || new Set(allowedRooms).size !== allowedRooms.length) {
    throw new Error('ALLOWED_ROOMS must contain unique comma-separated 64-character lowercase hex room IDs');
  }

  const stunURLs = list(env.STUN_URLS);
  if (stunURLs.length > 8 || stunURLs.some(url => !/^(?:stun|stuns):[^\s]{1,500}$/.test(url))) {
    throw new Error('STUN_URLS must contain at most 8 valid STUN URLs');
  }
  if (/\s/.test(env.BIND ?? '')) throw new Error('BIND must be a valid hostname or address');

  const approvedRoomsFile = env.APPROVED_ROOMS_FILE;
  const pendingRoomsFile = env.PENDING_ROOMS_FILE;
  if (pendingRoomsFile && !approvedRoomsFile) throw new Error('PENDING_ROOMS_FILE requires APPROVED_ROOMS_FILE');
  if (pendingRoomsFile === approvedRoomsFile && pendingRoomsFile !== undefined) {
    throw new Error('PENDING_ROOMS_FILE and APPROVED_ROOMS_FILE must be different paths');
  }
  const roomApproval = approvedRoomsFile ? createFileRoomApproval({
    approvedPath: approvedRoomsFile,
    pendingPath: pendingRoomsFile,
    pendingTTLSeconds: integer(env, 'PENDING_ROOM_TTL_SECONDS', 300, 60, 900),
  }) : undefined;

  const providerName = env.TURN_PROVIDER;
  let turnProvider: ServiceConfig['turnProvider'];
  if (providerName === 'coturn') {
    turnProvider = createCoturnProvider({
      urls: list(env.TURN_URLS),
      secret: requireValue(env, 'TURN_SECRET'),
      ttlSeconds: credentialTTLSeconds,
    });
  } else if (providerName === 'cloudflare') {
    turnProvider = createCloudflareTurnProvider({
      keyId: requireValue(env, 'CLOUDFLARE_TURN_KEY_ID'),
      apiToken: requireValue(env, 'CLOUDFLARE_TURN_KEY_API_TOKEN'),
      ttlSeconds: credentialTTLSeconds,
      timeoutMs: providerTimeoutMs,
      fetch: options.fetch,
    });
  } else if (providerName) {
    throw new Error('TURN_PROVIDER must be coturn or cloudflare');
  }

  if (production && allowedRooms.length === 0 && !roomApproval) {
    throw new Error('Production requires ALLOWED_ROOMS or APPROVED_ROOMS_FILE');
  }
  if (production && !turnProvider) throw new Error('Production requires TURN_PROVIDER=coturn or TURN_PROVIDER=cloudflare');
  const testForceRelay = flag(env, 'POCKETDESK_TEST_FORCE_RELAY');
  if (testForceRelay && !turnProvider) {
    throw new Error('POCKETDESK_TEST_FORCE_RELAY requires TURN_PROVIDER=coturn or TURN_PROVIDER=cloudflare');
  }

  return {
    hostname: env.BIND ?? '127.0.0.1',
    port,
    allowedRooms: allowedRooms.length ? allowedRooms : undefined,
    roomApproval,
    stunURLs,
    turnProvider,
    relayTimeoutMs: providerTimeoutMs,
    authTimeoutMs,
    maxPeers: integer(env, 'MAX_PEERS', 256, 2, 10_000),
    connectionAttemptsPerMinute: integer(env, 'CONNECTION_ATTEMPTS_PER_MINUTE', 30, 2, 10_000),
    messagesPerSecond: integer(env, 'MESSAGES_PER_SECOND', 100, 2, 1000),
    credentialIssuesPerMinute: integer(env, 'TURN_CREDENTIAL_ISSUES_PER_MINUTE', 12, 2, 120),
    maxRoomLifetimeMs: roomLifetimeSeconds * 1000,
    approvalAuditMs,
    testForceRelay,
  };
}
