#!/usr/bin/env bun
import { randomBytes, createHash } from 'node:crypto';
import { lstatSync, readFileSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { loadServiceConfig } from '../src/config';
import { preflightRelay, type Check } from '../src/relay-config';
import { mutateApprovedRooms, readApprovedRooms } from '../src/rooms';
import { resolveRelaySecrets, type KeychainPresence, type KeychainReader } from '../src/secrets';
import type { IceServer } from '../src/turn';

function option(name: string) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}
const hasFlag = (name: string) => process.argv.includes(name);
const usage = 'usage: readiness.ts --env-file /absolute/private/path [--offline] [--wss wss://host/signal | --public] [--slot a] [--cloudflared-config /absolute/path.yml]';

export type ReadinessOptions = {
  envFile: string;
  offline?: boolean;
  wss?: string;
  publicHost?: boolean;
  slot?: string;
  cloudflaredConfig?: string;
  repoRoot?: string;
  fetch?: typeof globalThis.fetch;
  keychainReader?: KeychainReader;
  keychainPresent?: KeychainPresence;
};

export function parsePrivateEnvFile(path: string): Record<string, string> {
  if (!isAbsolute(path)) throw new Error('environment file path must be absolute');
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0 || stat.size > 64 * 1024) {
    throw new Error('environment file must be a private regular file no larger than 64 KiB');
  }
  const result: Record<string, string> = {};
  for (const [index, source] of readFileSync(path, 'utf8').split(/\r?\n/).entries()) {
    const line = source.trim();
    if (!line || line.startsWith('#')) continue;
    const match = /^([A-Z][A-Z0-9_]*)=(.*)$/.exec(line);
    if (!match) throw new Error(`invalid environment line ${index + 1}`);
    let value = match[2];
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
    if (/[\r\n\0]/.test(value)) throw new Error(`invalid environment value on line ${index + 1}`);
    result[match[1]] = value;
  }
  return result;
}

export function summarizeIce(servers: IceServer[]) {
  if (!servers.length || servers.length > 8 || servers.some(server => !server.urls.length || server.urls.length > 8)) {
    throw new Error('ICE response exceeds native client limits');
  }
  const urls = servers.flatMap(server => server.urls);
  if (!urls.some(url => url.startsWith('turn:') || url.startsWith('turns:'))) throw new Error('ICE response has no TURN relay');
  for (const server of servers) {
    if (server.urls.some(url => url.startsWith('turn:') || url.startsWith('turns:')) && (!server.username || !server.credential)) {
      throw new Error('TURN relay is missing credentials');
    }
  }
  return {
    serverCount: servers.length,
    urlCount: urls.length,
    transports: [...new Set(urls.map(url => url.split(':', 1)[0]))].sort(),
  };
}

function websocket(url: string) {
  const socket = new WebSocket(url);
  const queued: unknown[] = [];
  const waiters: Array<(value: unknown) => void> = [];
  const opened = new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('WSS open timed out')), 10_000);
    socket.onopen = () => { clearTimeout(timer); resolve(); };
    socket.onerror = () => { clearTimeout(timer); reject(new Error('WSS connection failed')); };
  });
  socket.onmessage = event => {
    const value = JSON.parse(String(event.data));
    const waiter = waiters.shift();
    if (waiter) waiter(value); else queued.push(value);
  };
  const next = () => queued.length ? Promise.resolve(queued.shift()) : new Promise<unknown>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('WSS message timed out')), 10_000);
    waiters.push(value => { clearTimeout(timer); resolve(value); });
  });
  return { socket, opened, next };
}

const publicProbePaths = ['/health', '/ready', '/', '/browser-host', '/api/diagnostics'];

async function checkPublicRoutes(url: URL, fetcher: typeof globalThis.fetch): Promise<Record<string, number>> {
  const statuses: Record<string, number> = {};
  for (const path of publicProbePaths) {
    const response = await fetcher(new URL(path, `https://${url.host}`), {
      redirect: 'manual',
      signal: AbortSignal.timeout(10_000),
    });
    statuses[path] = response.status;
    await response.body?.cancel();
    if (response.status >= 200 && response.status < 300) throw new Error(`public route ${path} must not be reachable through the tunnel`);
  }
  return statuses;
}

async function checkPublicSignal(
  wssURL: string,
  env: Record<string, string>,
  expectedPolicy: 'all' | 'relay',
  fetcher: typeof globalThis.fetch,
) {
  const url = new URL(wssURL);
  if (url.protocol !== 'wss:' || url.pathname !== '/signal' || url.search || url.hash) throw new Error('--wss must be a clean wss://.../signal URL');
  if (!env.APPROVED_ROOMS_FILE) throw new Error('live WSS check requires APPROVED_ROOMS_FILE');
  const routes = await checkPublicRoutes(url, fetcher);
  const approvedPath = resolve(env.APPROVED_ROOMS_FILE);
  const hostToken = randomBytes(32).toString('hex');
  const publicRoom = createHash('sha256').update(hostToken).digest('hex');
  const clientToken = randomBytes(32).toString('hex');
  const original = readApprovedRooms(approvedPath);
  if (original.includes(publicRoom)) throw new Error('generated readiness room unexpectedly already exists');
  mutateApprovedRooms(approvedPath, current => current.includes(publicRoom) ? current : [...current, publicRoom]);
  const host = websocket(wssURL);
  const client = websocket(wssURL);
  try {
    await host.opened;
    host.socket.send(JSON.stringify({
      type: 'register', version: 1, role: 'host', room: publicRoom, token: hostToken,
      clientTokenHash: createHash('sha256').update(clientToken).digest('hex'),
    }));
    const hostRegistered = await host.next() as { type?: string };
    const hostIce = await host.next() as { type?: string; servers?: IceServer[]; policy?: string };
    if (hostRegistered.type !== 'registered' || hostIce.type !== 'ice' || !hostIce.servers) throw new Error('public host registration failed');
    const hostSummary = summarizeIce(hostIce.servers);

    await client.opened;
    client.socket.send(JSON.stringify({ type: 'register', version: 1, role: 'client', room: publicRoom, token: clientToken }));
    const clientRegistered = await client.next() as { type?: string };
    const clientIce = await client.next() as { type?: string; servers?: IceServer[]; policy?: string };
    if (clientRegistered.type !== 'registered' || clientIce.type !== 'ice' || !clientIce.servers) throw new Error('public client registration failed');
    const clientSummary = summarizeIce(clientIce.servers);
    for (const policy of [hostIce.policy, clientIce.policy]) {
      if ((policy ?? 'all') !== expectedPolicy) throw new Error(`public service ICE policy is not ${expectedPolicy}`);
    }
    return { tested: true, authenticatedPair: true, icePolicy: expectedPolicy, publicRouteStatuses: routes, hostIce: hostSummary, clientIce: clientSummary };
  } finally {
    host.socket.close();
    client.socket.close();
    mutateApprovedRooms(approvedPath, current => current.filter(room => room !== publicRoom));
  }
}

export async function runReadiness(options: ReadinessOptions) {
  const fileEnv = parsePrivateEnvFile(options.envFile);
  if (options.slot) fileEnv.POCKETDESK_KEYCHAIN_SLOT = options.slot;
  let resolvedEnv: Record<string, string | undefined> | undefined;
  let resolveError: string | undefined;
  try { resolvedEnv = await resolveRelaySecrets(fileEnv, { reader: options.keychainReader }); }
  catch (error) { resolveError = error instanceof Error ? error.message : String(error); }

  const preflight = await preflightRelay(fileEnv, {
    repoRoot: options.repoRoot,
    cloudflaredConfigPath: options.cloudflaredConfig ?? fileEnv.POCKETDESK_CLOUDFLARED_CONFIG,
    keychainPresent: options.keychainPresent,
    resolvedEnv,
    resolveError,
    fetch: options.fetch,
  });
  const mode = options.offline ? 'offline' : 'live';
  if (!preflight.ok || !resolvedEnv) return { status: 'blocked' as const, mode, checks: preflight.checks };

  const config = loadServiceConfig(resolvedEnv, { fetch: options.fetch });
  if (!config.turnProvider) throw new Error('production TURN provider is missing');
  const summary = {
    status: 'ready' as const,
    mode,
    checks: preflight.checks as Check[],
    productionConfig: true,
    provider: config.turnProvider.kind,
    requestedCredentialTTLSeconds: Number(fileEnv.TURN_CREDENTIAL_TTL_SECONDS ?? 3600),
    credentialIssuanceLimitPerMinute: config.credentialIssuesPerMinute,
    maxPeers: config.maxPeers,
    roomLifetimeSeconds: (config.maxRoomLifetimeMs ?? 0) / 1000,
    forceRelay: config.testForceRelay === true,
  };
  if (options.offline) return summary;

  const room = randomBytes(32).toString('hex');
  const directServers = await config.turnProvider.issue({ room, role: 'host' });
  const directSummary = summarizeIce(directServers);
  let directRevocation = 'expiry-only';
  if (config.turnProvider.revoke) {
    await config.turnProvider.revoke(directServers);
    directRevocation = 'confirmed';
  }
  const wssTarget = options.wss ?? (options.publicHost && fileEnv.PD_PUBLIC_HOST ? `wss://${fileEnv.PD_PUBLIC_HOST}/signal` : undefined);
  if (options.publicHost && !wssTarget) throw new Error('--public requires PD_PUBLIC_HOST in the environment file');
  const wssSummary = wssTarget
    ? await checkPublicSignal(wssTarget, fileEnv, config.testForceRelay ? 'relay' : 'all', options.fetch ?? globalThis.fetch)
    : { tested: false };
  return { ...summary, directCredentialCheck: { issued: true, revoked: directRevocation, ice: directSummary }, publicWSS: wssSummary };
}

async function main() {
  const envFile = option('--env-file');
  if (!envFile) throw new Error(usage);
  const report = await runReadiness({
    envFile,
    offline: hasFlag('--offline'),
    wss: option('--wss'),
    publicHost: hasFlag('--public'),
    slot: option('--slot'),
    cloudflaredConfig: option('--cloudflared-config'),
    repoRoot: resolve(import.meta.dir, '..', '..'),
  });
  console.log(JSON.stringify(report, null, 2));
  if (report.status === 'blocked') process.exit(1);
}

if (import.meta.main) {
  main().catch(error => {
    console.error(JSON.stringify({ status: 'blocked', reason: error instanceof Error ? error.message : String(error) }));
    process.exit(1);
  });
}
