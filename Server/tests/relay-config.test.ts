import { afterEach, beforeEach, expect, test } from 'bun:test';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkCloudflaredConfig, preflightRelay, publicHostCheck } from '../src/relay-config';
import { loadServiceConfig } from '../src/config';
import { parsePrivateEnvFile, runReadiness } from '../scripts/readiness';
import { initRelayHome, renderEnvTemplate, setEnvValue, tunnelIdFromJson } from '../scripts/relay-env';

const keyId = 'k'.repeat(32);
const apiToken = 't'.repeat(64);
const tunnelId = '6ff42ae2-765d-4adf-8112-31c55c1551ef';
let directory: string;

beforeEach(() => { directory = mkdtempSync(join(tmpdir(), 'pocketdesk-relay-')); });
afterEach(() => { rmSync(directory, { recursive: true, force: true }); });

function privateFile(name: string, content = '') {
  const path = join(directory, name);
  writeFileSync(path, content, { mode: 0o600 });
  chmodSync(path, 0o600);
  return path;
}

function goodEnv(overrides: Record<string, string | undefined> = {}) {
  return {
    NODE_ENV: 'production',
    BIND: '127.0.0.1',
    PORT: '28787',
    PD_PUBLIC_HOST: 'relay.pocketdesk-test.dev',
    POCKETDESK_SECRET_SOURCE: 'keychain',
    APPROVED_ROOMS_FILE: privateFile('approved-rooms'),
    PENDING_ROOMS_FILE: join(directory, 'pending-rooms.json'),
    TURN_PROVIDER: 'cloudflare',
    TURN_CREDENTIAL_TTL_SECONDS: '3600',
    ROOM_LIFETIME_SECONDS: '1800',
    MAX_PEERS: '4',
    TURN_CREDENTIAL_ISSUES_PER_MINUTE: '8',
    POCKETDESK_TEST_FORCE_RELAY: '0',
    ...overrides,
  } as Record<string, string | undefined>;
}

const allPresent = async () => true;
const resolvedFor = (env: Record<string, string | undefined>) => ({ ...env, CLOUDFLARE_TURN_KEY_ID: keyId, CLOUDFLARE_TURN_KEY_API_TOKEN: apiToken });
const levelOf = (report: Awaited<ReturnType<typeof preflightRelay>>, id: string) => report.checks.filter(check => check.id === id).map(check => check.level);

test('a correct relay configuration passes preflight and the report never carries secret values', async () => {
  const env = goodEnv();
  const report = await preflightRelay(env, { keychainPresent: allPresent, resolvedEnv: resolvedFor(env), repoRoot: '/nonexistent/repo' });
  expect(report.ok).toBe(true);
  expect(report.checks.filter(check => check.level === 'fail')).toEqual([]);
  expect(levelOf(report, 'service_config')).toEqual(['pass']);
  expect(JSON.stringify(report)).not.toContain(apiToken);
  expect(JSON.stringify(report)).not.toContain(keyId);
});

test('preflight fails closed on unsafe bind, lifetimes, approval file, Keychain and secret placement', async () => {
  const failing = async (overrides: Record<string, string | undefined>, options: Parameters<typeof preflightRelay>[1] = { keychainPresent: allPresent }) =>
    preflightRelay(goodEnv(overrides), options);

  expect(levelOf(await failing({ BIND: '0.0.0.0' }), 'bind')).toEqual(['fail']);
  expect(levelOf(await failing({ NODE_ENV: 'development' }), 'node_env')).toEqual(['fail']);
  expect(levelOf(await failing({ TURN_PROVIDER: undefined }), 'turn_provider')).toEqual(['fail']);
  expect(levelOf(await failing({ ROOM_LIFETIME_SECONDS: '3600' }), 'room_lifetime')).toEqual(['fail']);
  expect(levelOf(await failing({ TURN_CREDENTIAL_TTL_SECONDS: '43200', ROOM_LIFETIME_SECONDS: '3600' }), 'credential_ttl')).toEqual(['warn']);
  expect(levelOf(await failing({ MAX_PEERS: '64' }), 'max_peers')).toEqual(['warn']);
  expect(levelOf(await failing({ TURN_CREDENTIAL_ISSUES_PER_MINUTE: '60' }), 'issue_rate')).toEqual(['warn']);
  expect(levelOf(await failing({ POCKETDESK_TEST_FORCE_RELAY: '1' }), 'force_relay')).toEqual(['warn']);
  expect(levelOf(await failing({ POCKETDESK_SECRET_SOURCE: 'file' }), 'secret_source')).toEqual(['fail']);

  const loose = privateFile('loose-rooms');
  chmodSync(loose, 0o644);
  expect(levelOf(await failing({ APPROVED_ROOMS_FILE: loose }), 'approved_rooms')).toEqual(['fail']);
  expect(levelOf(await failing({ APPROVED_ROOMS_FILE: join(directory, 'missing') }), 'approved_rooms')).toEqual(['fail']);
  expect(levelOf(await failing({ APPROVED_ROOMS_FILE: undefined }), 'approved_rooms')).toEqual(['fail']);
  expect(levelOf(await failing({ APPROVED_ROOMS_FILE: undefined, ALLOWED_ROOMS: 'f'.repeat(64) }), 'approved_rooms')).toEqual(['warn']);
  expect(levelOf(await failing({}, { keychainPresent: allPresent, repoRoot: directory }), 'approved_rooms_location')).toEqual(['fail']);
  expect(levelOf(await failing({ PENDING_ROOMS_FILE: join(directory, 'no-such-dir', 'pending.json') }), 'pending_rooms')).toEqual(['fail']);

  const missingOne = await failing({}, { keychainPresent: async service => service.endsWith('turn-key-id') });
  expect(missingOne.ok).toBe(false);
  expect(missingOne.checks.find(check => check.id === 'keychain_turn-api-token')?.detail).toBe('Keychain item pocketdesk.cloudflare.turn-api-token is missing');

  const both = await failing({ CLOUDFLARE_TURN_KEY_API_TOKEN: apiToken });
  expect(both.checks.find(check => check.id === 'keychain_turn-api-token')?.level).toBe('fail');
  expect(JSON.stringify(both)).not.toContain(apiToken);

  const unreadable = await failing({}, { keychainPresent: async () => { throw new Error('keychain lookup failed for x (status 51)'); } });
  expect(levelOf(unreadable, 'keychain_turn-key-id')).toEqual(['fail']);
});

test('the public host must be a real first-level hostname, not a placeholder or URL', () => {
  expect(publicHostCheck('relay.pocketdesk-test.dev').level).toBe('pass');
  expect(publicHostCheck(undefined).level).toBe('warn');
  expect(publicHostCheck('relay.example.com').level).toBe('fail');
  expect(publicHostCheck('wss://relay.pocketdesk-test.dev/signal').level).toBe('fail');
  expect(publicHostCheck('relay.pocketdesk-test.dev:443').level).toBe('fail');
  expect(publicHostCheck('Relay.pocketdesk-test.dev').level).toBe('fail');
  expect(publicHostCheck('quick-abc.trycloudflare.com').level).toBe('warn');
  expect(publicHostCheck('a.b.pocketdesk-test.dev').level).toBe('warn');
});

function cloudflaredYaml(overrides: { credentials?: string; ingress?: string; extra?: string } = {}) {
  const credentials = overrides.credentials ?? privateFile('tunnel.json', '{}');
  return [
    `tunnel: ${tunnelId}`,
    `credentials-file: ${credentials}`,
    overrides.extra ?? '',
    overrides.ingress ?? [
      'ingress:',
      '  - hostname: relay.pocketdesk-test.dev',
      '    path: ^/signal$',
      '    service: http://127.0.0.1:28787',
      '  - service: http_status:404',
    ].join('\n'),
    '',
  ].join('\n');
}

function writeCloudflared(content: string, mode = 0o600) {
  const path = join(directory, 'cloudflared.yml');
  writeFileSync(path, content, { mode });
  chmodSync(path, mode);
  return path;
}

const failedIds = (checks: ReturnType<typeof checkCloudflaredConfig>) => checks.filter(check => check.level === 'fail').map(check => check.id);

test('the cloudflared config check accepts only a signal-only, loopback, catch-all-404 ingress', () => {
  const good = checkCloudflaredConfig(writeCloudflared(cloudflaredYaml()), 'relay.pocketdesk-test.dev', 28787);
  expect(failedIds(good)).toEqual([]);
  expect(good.find(check => check.id === 'ingress_path')?.level).toBe('pass');
});

test('the cloudflared config check rejects leaking paths, wrong origins, missing catch-all, and loose credentials', () => {
  const host = 'relay.pocketdesk-test.dev';
  const rule = (path: string | undefined, service = 'http://127.0.0.1:28787', hostname = host) => [
    'ingress:', `  - hostname: ${hostname}`, ...(path ? [`    path: ${path}`] : []), `    service: ${service}`, '  - service: http_status:404',
  ].join('\n');

  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ ingress: rule(undefined) })), host, 28787))).toContain('ingress_path');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ ingress: rule('.*') })), host, 28787))).toContain('ingress_path');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ ingress: rule('^/signal') })), host, 28787))).toContain('ingress_path');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ ingress: rule('^/(signal|health)$') })), host, 28787))).toContain('ingress_path');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ ingress: rule('^/sig$') })), host, 28787))).toContain('ingress_path');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ ingress: rule('^/signal$', 'http://192.168.1.5:28787') })), host, 28787))).toContain('ingress_origin');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ ingress: rule('^/signal$', 'http://127.0.0.1:9999') })), host, 28787))).toContain('ingress_origin');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ ingress: rule('^/signal$', 'https://127.0.0.1:28787') })), host, 28787))).toContain('ingress_origin');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ ingress: rule('^/signal$', undefined, 'other.pocketdesk-test.dev') })), host, 28787))).toContain('ingress_hostname');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ ingress: [
    'ingress:', `  - hostname: ${host}`, '    path: ^/signal$', '    service: http://127.0.0.1:28787',
  ].join('\n') })), host, 28787))).toContain('ingress');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ ingress: [
    'ingress:', `  - hostname: ${host}`, '    path: ^/signal$', '    service: http://127.0.0.1:28787', '  - service: http://127.0.0.1:1',
  ].join('\n') })), host, 28787))).toContain('ingress_catch_all');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ ingress: [
    'ingress:', `  - hostname: ${host}`, '    path: ^/signal$', '    service: http://127.0.0.1:28787',
    '  - hostname: other.pocketdesk-test.dev', '    service: http://127.0.0.1:1', '  - service: http_status:404',
  ].join('\n') })), host, 28787))).toContain('ingress_rules');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ extra: 'warp-routing:\n  enabled: true' })), host, 28787))).toContain('warp_routing');

  const loose = privateFile('loose-credentials.json', '{}');
  chmodSync(loose, 0o644);
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ credentials: loose })), host, 28787))).toContain('tunnel_credentials');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml({ credentials: join(directory, 'absent.json') })), host, 28787))).toContain('tunnel_credentials');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared(cloudflaredYaml(), 0o666), host, 28787))).toContain('cloudflared_config_permissions');
  expect(failedIds(checkCloudflaredConfig(writeCloudflared('tunnel: nope\n'), host, 28787))).toContain('tunnel_id');
  expect(failedIds(checkCloudflaredConfig(join(directory, 'nothing.yml'), host, 28787))).toEqual(['cloudflared_config']);
});

function writeRelayEnv(overrides: Record<string, string | undefined> = {}) {
  const env = goodEnv(overrides);
  delete env.APPROVED_ROOMS_FILE;
  const lines = Object.entries({ ...env, APPROVED_ROOMS_FILE: goodEnv().APPROVED_ROOMS_FILE, ...overrides })
    .filter((entry): entry is [string, string] => entry[1] !== undefined)
    .map(([key, value]) => `${key}=${value}`);
  return privateFile('relay.env', `${lines.join('\n')}\n`);
}

function readerFor(items: Record<string, string>) {
  return async (service: string) => items[service];
}
const keychainItems = { 'pocketdesk.cloudflare.turn-key-id': keyId, 'pocketdesk.cloudflare.turn-api-token': apiToken };

function counting(handler: (url: string) => Response) {
  const urls: string[] = [];
  const fetch: typeof globalThis.fetch = async input => { urls.push(String(input)); return handler(String(input)); };
  return { urls, fetch };
}

test('offline readiness validates everything with zero network calls and prints no secret material', async () => {
  const network = counting(() => { throw new Error('offline mode must not use the network'); });
  const report = await runReadiness({
    envFile: writeRelayEnv(), offline: true, fetch: network.fetch,
    keychainReader: readerFor(keychainItems), keychainPresent: allPresent, repoRoot: '/nonexistent/repo',
  });
  expect(report.status).toBe('ready');
  expect(report).toMatchObject({ mode: 'offline', provider: 'cloudflare', credentialIssuanceLimitPerMinute: 8, maxPeers: 4, roomLifetimeSeconds: 1800, forceRelay: false });
  expect(network.urls).toEqual([]);
  expect(JSON.stringify(report)).not.toContain(apiToken);
  expect(JSON.stringify(report)).not.toContain(keyId);
});

test('live readiness makes exactly one issuance and one revocation call and prints no credential', async () => {
  const network = counting(url => url.endsWith('/generate-ice-servers')
    ? Response.json({ iceServers: [
      { urls: ['stun:stun.cloudflare.com:3478'] },
      { urls: ['turn:turn.cloudflare.com:3478?transport=udp'], username: 'secret-user', credential: 'secret-credential' },
    ] }, { status: 201 })
    : new Response(null, { status: 204 }));
  const report = await runReadiness({
    envFile: writeRelayEnv(), fetch: network.fetch,
    keychainReader: readerFor(keychainItems), keychainPresent: allPresent, repoRoot: '/nonexistent/repo',
  });
  expect(report.status).toBe('ready');
  expect(network.urls).toEqual([
    `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate-ice-servers`,
    `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/secret-user/revoke`,
  ]);
  const serialized = JSON.stringify(report);
  expect(serialized).toContain('"revoked":"confirmed"');
  for (const secret of [apiToken, keyId, 'secret-user', 'secret-credential']) expect(serialized).not.toContain(secret);
});

test('readiness is blocked before any network call when a Keychain secret is missing', async () => {
  const network = counting(() => { throw new Error('must not be reached'); });
  const report = await runReadiness({
    envFile: writeRelayEnv(), fetch: network.fetch,
    keychainReader: readerFor({ 'pocketdesk.cloudflare.turn-key-id': keyId }), keychainPresent: async service => service.endsWith('turn-key-id'),
  });
  expect(report.status).toBe('blocked');
  expect(network.urls).toEqual([]);
  expect(report.checks.find(check => check.id === 'secret_resolution')?.detail).toBe('Keychain item pocketdesk.cloudflare.turn-api-token is missing or empty');
});

test('readiness can verify the alternate Keychain slot used during key rotation', async () => {
  const requested: string[] = [];
  const network = counting(url => url.endsWith('/generate-ice-servers')
    ? Response.json({ iceServers: [{ urls: ['turn:turn.cloudflare.com:3478'], username: 'u', credential: 'c' }] }, { status: 201 })
    : new Response(null, { status: 204 }));
  const report = await runReadiness({
    envFile: writeRelayEnv(), slot: 'b', fetch: network.fetch, keychainPresent: allPresent, repoRoot: '/nonexistent/repo',
    keychainReader: async service => { requested.push(service); return keychainItems[service.replace(/\.b$/, '') as keyof typeof keychainItems]; },
  });
  expect(report.status).toBe('ready');
  expect(requested).toEqual(['pocketdesk.cloudflare.turn-key-id.b', 'pocketdesk.cloudflare.turn-api-token.b']);
});

test('the shipped example renders into a valid private configuration that matches the documented relay policy', async () => {
  const home = join(directory, 'home');
  mkdirSync(home);
  const result = initRelayHome({ host: 'relay.pocketdesk-test.dev', env: { HOME: home, POCKETDESK_HOME: join(home, '.pocketdesk', 'relay') } });
  expect(statSync(result.envFile).mode & 0o777).toBe(0o600);
  expect(statSync(result.approved).mode & 0o777).toBe(0o600);
  expect(statSync(result.home).mode & 0o777).toBe(0o700);
  const parsed = parsePrivateEnvFile(result.envFile);
  expect(parsed).toMatchObject({
    NODE_ENV: 'production', BIND: '127.0.0.1', PORT: '28787', PD_PUBLIC_HOST: 'relay.pocketdesk-test.dev',
    PD_TUNNEL_NAME: 'pocketdesk-relay', POCKETDESK_SECRET_SOURCE: 'keychain', POCKETDESK_KEYCHAIN_SLOT: 'a',
    TURN_CREDENTIAL_TTL_SECONDS: '3600', ROOM_LIFETIME_SECONDS: '1800', MAX_PEERS: '4',
    TURN_CREDENTIAL_ISSUES_PER_MINUTE: '8', POCKETDESK_TEST_FORCE_RELAY: '0',
  });
  expect(parsed.APPROVED_ROOMS_FILE).toBe(result.approved);
  expect(readFileSync(result.envFile, 'utf8')).not.toContain('@');

  const config = loadServiceConfig({ ...parsed, CLOUDFLARE_TURN_KEY_ID: keyId, CLOUDFLARE_TURN_KEY_API_TOKEN: apiToken, POCKETDESK_SECRET_SOURCE: undefined });
  expect(config.credentialIssuesPerMinute).toBe(8);
  expect(config.maxPeers).toBe(4);
  expect(config.maxRoomLifetimeMs).toBe(1_800_000);
  expect(config.testForceRelay).toBe(false);
  expect(config.hostname).toBe('127.0.0.1');
  expect(() => initRelayHome({ host: 'relay.pocketdesk-test.dev', env: { HOME: home, POCKETDESK_HOME: result.home } })).toThrow('already exists');
  expect(() => initRelayHome({ host: 'relay.example.com', force: true, env: { HOME: home, POCKETDESK_HOME: result.home } })).toThrow('placeholder');

  const report = await preflightRelay(parsed, { keychainPresent: allPresent, repoRoot: '/nonexistent/repo' });
  expect(report.checks.filter(check => check.level === 'fail')).toEqual([]);
});

test('relay-env edits are atomic, keep mode 600, validate input and never accept unsafe values', () => {
  const path = writeRelayEnv();
  setEnvValue(path, 'POCKETDESK_KEYCHAIN_SLOT', 'b');
  expect(parsePrivateEnvFile(path).POCKETDESK_KEYCHAIN_SLOT).toBe('b');
  setEnvValue(path, 'POCKETDESK_TEST_FORCE_RELAY', '1');
  expect(parsePrivateEnvFile(path).POCKETDESK_TEST_FORCE_RELAY).toBe('1');
  setEnvValue(path, 'PD_NEW_SETTING', 'value');
  expect(parsePrivateEnvFile(path).PD_NEW_SETTING).toBe('value');
  expect(statSync(path).mode & 0o777).toBe(0o600);
  expect(() => setEnvValue(path, 'lower', 'x')).toThrow('invalid key');
  expect(() => setEnvValue(path, 'PD_X', 'a b')).toThrow('invalid value');
  expect(() => setEnvValue(path, 'PD_X', '$(id)')).toThrow('invalid value');
  chmodSync(path, 0o644);
  expect(() => setEnvValue(path, 'PD_X', 'y')).toThrow('private regular file');
});

test('template rendering rejects unresolved placeholders and tunnel ids are read from cloudflared JSON', () => {
  expect(() => renderEnvTemplate('X=@UNKNOWN@', { home: '/h', userHome: '/u' })).toThrow('unresolved template placeholder');
  expect(renderEnvTemplate('@PD_PUBLIC_HOST_LINE@', { home: '/h', userHome: '/u' })).toContain('# PD_PUBLIC_HOST=');
  const json = JSON.stringify([
    { id: 'old', name: 'pocketdesk-relay', deleted_at: '2026-09-01T00:00:00Z' },
    { id: tunnelId, name: 'pocketdesk-relay', deleted_at: '0001-01-01T00:00:00Z' },
    { id: 'other', name: 'other' },
  ]);
  expect(tunnelIdFromJson(JSON.stringify([{ id: tunnelId, name: 'pocketdesk-relay' }]), 'pocketdesk-relay')).toBe(tunnelId);
  expect(tunnelIdFromJson('[]', 'pocketdesk-relay')).toBeUndefined();
  expect(tunnelIdFromJson(json, 'pocketdesk-relay')).toBe(tunnelId);
  expect(tunnelIdFromJson(json, 'missing')).toBeUndefined();
  expect(() => tunnelIdFromJson('{}', 'x')).toThrow('unexpected tunnel list output');
});
