import { afterEach, expect, test } from 'bun:test';
import { createHmac } from 'node:crypto';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadServiceConfig } from '../src/config';
import { createService, digest } from '../src/server';
import { createCloudflareTurnProvider, createCoturnProvider } from '../src/turn';
import { createFileRoomApproval, mutateApprovedRooms, readApprovedRooms, readPendingRooms, writeApprovedRooms } from '../src/rooms';
const hostToken = 'a'.repeat(64), clientToken = 'b'.repeat(64), room = digest(hostToken);
const instances: ReturnType<typeof createService>[] = [];
const temporaryDirectories: string[] = [];
afterEach(async () => {
  await Promise.all(instances.map(app => app.stop(100))); instances.length = 0;
  for (const path of temporaryDirectories) rmSync(path, { recursive: true, force: true });
  temporaryDirectories.length = 0;
});
function privateFile(name: string) {
  const directory = mkdtempSync(join(tmpdir(), 'pocketdesk-rooms-'));
  temporaryDirectories.push(directory);
  const path = join(directory, name);
  writeFileSync(path, '', { mode: 0o600 }); chmodSync(path, 0o600);
  return path;
}
function setup() { const app = createService({ port: 0 }); instances.push(app); return app; }
function peer(app: ReturnType<typeof setup>) {
  const ws = new WebSocket(`ws://127.0.0.1:${app.server.port}/signal`), messages: any[] = [], waiters: ((v: any) => void)[] = [];
  ws.onmessage = e => { const value = JSON.parse(String(e.data)), waiter = waiters.shift(); if (waiter) waiter(value); else messages.push(value); };
  const open = new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = reject; });
  const next = () => messages.length ? Promise.resolve(messages.shift()) : new Promise<any>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('message timeout')), 2000); waiters.push(value => { clearTimeout(timer); resolve(value); });
  });
  return { ws, open, next, messages, send: (v: unknown) => ws.send(JSON.stringify(v)) };
}
const register = (role: string, token = role === 'host' ? hostToken : clientToken) => ({ type: 'register', version: 1, role, room, token, clientTokenHash: digest(clientToken) });
async function connectHost(app: ReturnType<typeof setup>) { const h = peer(app); await h.open; h.send(register('host')); expect((await h.next()).type).toBe('registered'); await h.next(); return h; }
test('authenticated opaque exchange and duplicate admission safety', async () => {
  const app = setup(), h = await connectHost(app), c = peer(app); await c.open; c.send(register('client'));
  expect((await c.next()).type).toBe('registered'); await c.next(); expect((await c.next()).online).toBe(true); await h.next();
  const payload = Buffer.alloc(64, 7).toString('base64'); c.send({ type: 'signal', payload }); expect((await h.next()).payload).toBe(payload);
  const duplicate = peer(app); await duplicate.open; duplicate.send(register('client')); expect((await duplicate.next()).code).toBe('already_connected');
  h.send({ type: 'signal', payload }); expect((await c.next()).payload).toBe(payload);
});
test('wrong client token cannot join', async () => { const app = setup(); await connectHost(app); const c = peer(app); await c.open; c.send(register('client', 'c'.repeat(64))); expect((await c.next()).type).toBe('error'); });
test('phone-before-host is terminal on that socket but a fresh retry can join', async () => {
  const app = setup(), early = peer(app); await early.open; early.send(register('client'));
  expect((await early.next()).code).toBe('host_unavailable_or_unauthorized');
  const host = await connectHost(app);
  const retry = peer(app); await retry.open; retry.send(register('client'));
  expect((await retry.next()).type).toBe('registered');
  expect((await retry.next()).type).toBe('ice');
  expect((await retry.next()).online).toBe(true);
  expect((await host.next()).online).toBe(true);
});
test('host identity and version checked', async () => {
  const app = setup(), h = peer(app); await h.open; h.send(register('host', 'd'.repeat(64))); expect((await h.next()).code).toBe('unauthorized');
  const c = peer(app); await c.open; c.send({ ...register('client'), version: 2 }); expect((await c.next()).code).toBe('invalid_registration');
});
test('unregistered signals and malformed JSON fail closed', async () => {
  const app = setup(), c = peer(app); await c.open; c.send({ type: 'signal', payload: 'a'.repeat(64) }); expect((await c.next()).type).toBe('error');
  const d = peer(app); await d.open; d.ws.send('{'); expect((await d.next()).code).toBe('invalid_message');
});
test('host disconnect closes client and removes room', async () => {
  const app = setup(), h = await connectHost(app), c = peer(app); await c.open; c.send(register('client')); await c.next(); await c.next(); await c.next(); await h.next();
  const closed = new Promise(resolve => { c.ws.onclose = resolve; }); h.ws.close(); await closed; expect(app.roomCount()).toBe(0);
});
test('payload limit rejects oversized signal', async () => { const app = setup(), h = await connectHost(app); h.send({ type: 'signal', payload: 'a'.repeat(190 * 1024) }); expect((await h.next()).code).toBe('invalid_message'); });
test('production-style approval list blocks unapproved TURN consumers', async () => {
 const app = createService({ port: 0, allowedRooms: ['f'.repeat(64)] }); instances.push(app);
 const h = peer(app); await h.open; h.send(register('host')); expect((await h.next()).code).toBe('room_not_approved');
});

test('coturn provider remains an explicit expiring shared-secret mode', async () => {
  const provider = createCoturnProvider({
    urls: ['turn:relay.example.test:3478?transport=udp'],
    secret: 's'.repeat(32),
    ttlSeconds: 600,
    now: () => 1_000_000,
  });
  const [server] = await provider.issue({ room, role: 'host' });
  expect(provider.kind).toBe('coturn');
  expect(server.username?.startsWith('1600:')).toBe(true);
  expect(server.credential).toBe(createHmac('sha1', 's'.repeat(32)).update(server.username!).digest('base64'));
});

test('Cloudflare provider uses the official expiring ICE credential endpoint', async () => {
  const apiToken = 't'.repeat(64), keyId = 'k'.repeat(32);
  const provider = createCloudflareTurnProvider({
    keyId,
    apiToken,
    ttlSeconds: 900,
    timeoutMs: 100,
    fetch: async (input, init) => {
      expect(String(input)).toBe(`https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate-ice-servers`);
      expect(init?.method).toBe('POST');
      expect(new Headers(init?.headers).get('authorization')).toBe(`Bearer ${apiToken}`);
      expect(JSON.parse(String(init?.body))).toEqual({ ttl: 900 });
      return Response.json({ iceServers: [
        { urls: ['stun:stun.cloudflare.com:3478'] },
        { urls: ['turn:turn.cloudflare.com:3478?transport=udp'], username: 'short-user', credential: 'short-credential' },
      ] }, { status: 201 });
    },
  });
  const app = createService({ port: 0, turnProvider: provider }); instances.push(app);
  const h = peer(app); await h.open; h.send(register('host'));
  expect(await h.next()).toEqual({ type: 'registered', role: 'host' });
  expect(await h.next()).toEqual({ type: 'ice', servers: [
    { urls: ['stun:stun.cloudflare.com:3478'] },
    { urls: ['turn:turn.cloudflare.com:3478?transport=udp'], username: 'short-user', credential: 'short-credential' },
  ] });
});

test('Cloudflare credentials are revoked without exposing them after disconnect', async () => {
  const calls: string[] = [];
  const provider = createCloudflareTurnProvider({
    keyId: 'k'.repeat(32), apiToken: 't'.repeat(64), ttlSeconds: 900, timeoutMs: 100,
    fetch: async input => {
      calls.push(String(input));
      if (String(input).endsWith('/generate-ice-servers')) {
        return Response.json({ iceServers: [{
          urls: ['turn:turn.cloudflare.com:3478?transport=udp'], username: 'short-user', credential: 'short-credential',
        }] }, { status: 201 });
      }
      return new Response(null, { status: 204 });
    },
  });
  const app = createService({ port: 0, turnProvider: provider }); instances.push(app);
  const h = await connectHost(app);
  h.ws.close();
  await new Promise(resolve => setTimeout(resolve, 20));
  expect(calls.some(url => url.endsWith('/credentials/short-user/revoke'))).toBe(true);
});

test('bounded shutdown waits for connected peer credential revocation', async () => {
  let revoked = false;
  const app = createService({
    port: 0,
    turnProvider: {
      kind: 'cloudflare',
      issue: async () => [{ urls: ['turn:relay.example.test'], username: 'issued', credential: 'credential' }],
      revoke: async () => { await new Promise(resolve => setTimeout(resolve, 30)); revoked = true; },
    },
  });
  instances.push(app);
  await connectHost(app);
  await app.stop(200);
  expect(revoked).toBe(true);
});

test('late credential issuance after socket close is revoked before bounded shutdown returns', async () => {
  let resolveIssue!: (servers: Array<{ urls: string[]; username: string; credential: string }>) => void;
  let issueStarted!: () => void;
  const started = new Promise<void>(resolve => { issueStarted = resolve; });
  let revoked = false;
  const app = createService({
    port: 0,
    relayTimeoutMs: 500,
    turnProvider: {
      kind: 'cloudflare',
      issue: () => { issueStarted(); return new Promise(resolve => { resolveIssue = resolve; }); },
      revoke: async () => { revoked = true; },
    },
  });
  instances.push(app);
  const host = peer(app); await host.open; host.send(register('host')); await started;
  host.ws.close();
  const stopping = app.stop(500);
  await new Promise(resolve => setTimeout(resolve, 20));
  resolveIssue([{ urls: ['turn:relay.example.test'], username: 'late', credential: 'credential' }]);
  await stopping;
  expect(revoked).toBe(true);
  expect(app.roomCount()).toBe(0);
});

test('provider response after relay timeout is revoked during bounded shutdown', async () => {
  let resolveIssue!: (servers: Array<{ urls: string[]; username: string; credential: string }>) => void;
  let revoked = false;
  const app = createService({
    port: 0,
    relayTimeoutMs: 20,
    turnProvider: {
      kind: 'cloudflare',
      issue: () => new Promise(resolve => { resolveIssue = resolve; }),
      revoke: async () => { revoked = true; },
    },
  });
  instances.push(app);
  const host = peer(app); await host.open; host.send(register('host'));
  expect((await host.next()).code).toBe('relay_unavailable');
  const stopping = app.stop(500);
  resolveIssue([{ urls: ['turn:relay.example.test'], username: 'timed-out', credential: 'credential' }]);
  await stopping;
  expect(revoked).toBe(true);
});

test('provider errors fail registration closed without retaining a room', async () => {
  const provider = createCloudflareTurnProvider({
    keyId: 'k'.repeat(32), apiToken: 't'.repeat(64), ttlSeconds: 900, timeoutMs: 100,
    fetch: async () => new Response('denied', { status: 401 }),
  });
  const app = createService({ port: 0, turnProvider: provider }); instances.push(app);
  const h = peer(app); await h.open; h.send(register('host'));
  expect(await h.next()).toEqual({ type: 'error', code: 'relay_unavailable' });
  expect(app.roomCount()).toBe(0);
});

test('provider timeouts fail registration closed without real credentials', async () => {
  const provider = createCloudflareTurnProvider({
    keyId: 'k'.repeat(32), apiToken: 't'.repeat(64), ttlSeconds: 900, timeoutMs: 20,
    fetch: ((_input: RequestInfo | URL, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
    })) as typeof fetch,
  });
  const app = createService({ port: 0, turnProvider: provider, authTimeoutMs: 500 }); instances.push(app);
  const h = peer(app); await h.open; h.send(register('host'));
  expect(await h.next()).toEqual({ type: 'error', code: 'relay_unavailable' });
  expect(app.roomCount()).toBe(0);
});

test('service timeout bounds a provider that ignores cancellation', async () => {
  const app = createService({
    port: 0,
    authTimeoutMs: 500,
    relayTimeoutMs: 20,
    turnProvider: {
      kind: 'cloudflare',
      issue: () => new Promise(() => {}),
    },
  });
  instances.push(app);
  const h = peer(app); await h.open; h.send(register('host'));
  expect(await h.next()).toEqual({ type: 'error', code: 'relay_unavailable' });
  expect(app.roomCount()).toBe(0);
});

test('malformed provider success cannot authorize a room', async () => {
  const provider = createCloudflareTurnProvider({
    keyId: 'k'.repeat(32), apiToken: 't'.repeat(64), ttlSeconds: 900, timeoutMs: 100,
    fetch: async () => Response.json({ iceServers: [{ urls: ['stun:only.example.test'] }] }, { status: 201 }),
  });
  const app = createService({ port: 0, turnProvider: provider }); instances.push(app);
  const h = peer(app); await h.open; h.send(register('host'));
  expect((await h.next()).code).toBe('relay_unavailable');
  expect(app.roomCount()).toBe(0);
});

test('oversized provider response cannot authorize a room', async () => {
  const provider = createCloudflareTurnProvider({
    keyId: 'k'.repeat(32), apiToken: 't'.repeat(64), ttlSeconds: 900, timeoutMs: 100,
    fetch: async () => new Response(JSON.stringify({ padding: 'x'.repeat(65 * 1024), iceServers: [] }), { status: 201 }),
  });
  const app = createService({ port: 0, turnProvider: provider }); instances.push(app);
  const h = peer(app); await h.open; h.send(register('host'));
  expect((await h.next()).code).toBe('relay_unavailable');
  expect(app.roomCount()).toBe(0);
});

test('provider output cannot exceed native ICE limits', async () => {
  const app = createService({
    port: 0,
    stunURLs: ['stun:local.example.test'],
    turnProvider: {
      kind: 'cloudflare',
      issue: async () => Array.from({ length: 8 }, (_, index) => ({
        urls: [`turn:relay${index}.example.test`], username: 'user', credential: 'credential',
      })),
    },
  });
  instances.push(app);
  const h = peer(app); await h.open; h.send(register('host'));
  expect((await h.next()).code).toBe('relay_unavailable');
  expect(app.roomCount()).toBe(0);
});

test('credential issuance and room lifetime have hard service bounds', async () => {
  const secondToken = 'c'.repeat(64), secondRoom = digest(secondToken);
  const provider = { kind: 'cloudflare' as const, issue: async () => [{ urls: ['turn:relay.example.test'], username: 'u', credential: 'c' }] };
  const app = createService({
    port: 0, turnProvider: provider, allowedRooms: [room, secondRoom], credentialIssuesPerMinute: 1, maxRoomLifetimeMs: 30,
  });
  instances.push(app);
  const h = peer(app); await h.open; h.send(register('host'));
  expect((await h.next()).type).toBe('registered'); await h.next();
  const second = peer(app); await second.open;
  second.send({ ...register('host', secondToken), room: secondRoom });
  expect((await second.next()).code).toBe('relay_unavailable');
  await new Promise(resolve => setTimeout(resolve, 60));
  expect(app.roomCount()).toBe(0);
});

test('file approval queues only self-authenticating hosts and supports exact retry', async () => {
  const approvedPath = privateFile('approved');
  const pendingPath = join(join(approvedPath, '..'), 'pending.json');
  const approval = createFileRoomApproval({ approvedPath, pendingPath });
  const app = createService({ port: 0, roomApproval: approval }); instances.push(app);

  const invalid = peer(app); await invalid.open;
  invalid.send({ ...register('host', 'c'.repeat(64)), room });
  expect((await invalid.next()).code).toBe('unauthorized');
  expect(readPendingRooms(pendingPath)).toEqual([]);

  const first = peer(app); await first.open; first.send(register('host'));
  expect((await first.next()).code).toBe(`room_pending_${room.slice(0, 12)}`);
  expect(readPendingRooms(pendingPath).map(item => item.fingerprint)).toEqual([room.slice(0, 12)]);
  writeApprovedRooms(approvedPath, [room]);

  const retry = peer(app); await retry.open; retry.send(register('host'));
  expect((await retry.next()).type).toBe('registered');
  expect((await retry.next()).type).toBe('ice');
  expect(readApprovedRooms(approvedPath)).toEqual([room]);
});

test('file revocation closes both live peers, removes the room, stops signaling, and drains TURN revocation', async () => {
  const approvedPath = privateFile('approved');
  writeApprovedRooms(approvedPath, [room]);
  const revoked: string[] = [];
  const releaseRevocations: Array<() => void> = [];
  const app = createService({
    port: 0,
    roomApproval: createFileRoomApproval({ approvedPath }),
    approvalAuditMs: 100,
    turnProvider: {
      kind: 'cloudflare',
      issue: async ({ role }) => [{ urls: ['turn:relay.example.test'], username: role, credential: 'credential' }],
      revoke: async servers => {
        revoked.push(servers[0].username!);
        await new Promise<void>(resolve => releaseRevocations.push(resolve));
      },
    },
  });
  instances.push(app);
  const host = await connectHost(app);
  const client = peer(app); await client.open; client.send(register('client'));
  expect((await client.next()).type).toBe('registered');
  await client.next();
  expect((await client.next()).online).toBe(true);
  expect((await host.next()).online).toBe(true);

  const hostClosed = new Promise<CloseEvent>(resolve => { host.ws.onclose = resolve; });
  const clientClosed = new Promise<CloseEvent>(resolve => { client.ws.onclose = resolve; });
  const startedAt = Date.now();
  mutateApprovedRooms(approvedPath, current => current.filter(item => item !== room));
  const [hostClose, clientClose] = await Promise.all([hostClosed, clientClosed]);

  expect(Date.now() - startedAt).toBeLessThan(1000);
  expect(hostClose.code).toBe(1008);
  expect(clientClose.code).toBe(1008);
  expect(app.roomCount()).toBe(0);
  expect(revoked.sort()).toEqual(['client', 'host']);

  const payload = Buffer.alloc(64, 4).toString('base64');
  expect(host.ws.readyState).toBe(WebSocket.CLOSED);
  expect(client.ws.readyState).toBe(WebSocket.CLOSED);
  host.send({ type: 'signal', payload });
  await Bun.sleep(20);
  expect(client.messages.some(message => message.type === 'signal')).toBe(false);

  let stopped = false;
  const stopping = app.stop(500).then(() => { stopped = true; });
  await Bun.sleep(20);
  expect(stopped).toBe(false);
  for (const release of releaseRevocations) release();
  await stopping;
  expect(stopped).toBe(true);
});

test('file revocation during TURN issuance cannot create a room and revokes the issued credential', async () => {
  const approvedPath = privateFile('approved');
  writeApprovedRooms(approvedPath, [room]);
  let issueStarted!: () => void;
  let resolveIssue!: (servers: Array<{ urls: string[]; username: string; credential: string }>) => void;
  const started = new Promise<void>(resolve => { issueStarted = resolve; });
  const revoked: string[] = [];
  const app = createService({
    port: 0,
    roomApproval: createFileRoomApproval({ approvedPath }),
    turnProvider: {
      kind: 'cloudflare',
      issue: () => { issueStarted(); return new Promise(resolve => { resolveIssue = resolve; }); },
      revoke: async servers => { revoked.push(servers[0].username!); },
    },
  });
  instances.push(app);
  const host = peer(app); await host.open; host.send(register('host'));
  await started;
  mutateApprovedRooms(approvedPath, current => current.filter(item => item !== room));
  resolveIssue([{ urls: ['turn:relay.example.test'], username: 'revoked-before-register', credential: 'credential' }]);

  expect(await host.next()).toEqual({ type: 'error', code: 'room_not_approved' });
  await Bun.sleep(20);
  expect(app.roomCount()).toBe(0);
  expect(revoked).toEqual(['revoked-before-register']);
});

test('authentication and message rates have concrete bounded failures', async () => {
  const authApp = createService({ port: 0, authTimeoutMs: 20 }); instances.push(authApp);
  const unauthenticated = peer(authApp); await unauthenticated.open;
  expect(await unauthenticated.next()).toEqual({ type: 'error', code: 'authentication_timeout' });

  const rateApp = createService({ port: 0, messagesPerSecond: 2 }); instances.push(rateApp);
  const host = await connectHost(rateApp);
  const payload = Buffer.alloc(64, 1).toString('base64');
  host.send({ type: 'signal', payload });
  expect((await host.next()).code).toBe('peer_unavailable');
  host.send({ type: 'signal', payload });
  expect((await host.next()).code).toBe('rate_limit');
});

test('connection attempt and open-peer limits reject before upgrade', async () => {
  const attemptsApp = createService({ port: 0, connectionAttemptsPerMinute: 2 }); instances.push(attemptsApp);
  const attemptsURL = `http://127.0.0.1:${attemptsApp.server.port}/signal`;
  expect((await fetch(attemptsURL)).status).toBe(426);
  expect((await fetch(attemptsURL)).status).toBe(426);
  expect((await fetch(attemptsURL)).status).toBe(429);

  const peersApp = createService({ port: 0, maxPeers: 1 }); instances.push(peersApp);
  const openPeer = peer(peersApp); await openPeer.open;
  expect((await fetch(`http://127.0.0.1:${peersApp.server.port}/signal`)).status).toBe(503);
});

test('production configuration requires approved rooms and one complete relay provider', () => {
  expect(() => loadServiceConfig({ NODE_ENV: 'production' })).toThrow('Production requires ALLOWED_ROOMS or APPROVED_ROOMS_FILE');
  expect(() => loadServiceConfig({
    NODE_ENV: 'production', ALLOWED_ROOMS: room, TURN_PROVIDER: 'cloudflare',
    CLOUDFLARE_TURN_KEY_ID: 'k'.repeat(32),
  })).toThrow('CLOUDFLARE_TURN_KEY_API_TOKEN is required');
  expect(() => loadServiceConfig({
    NODE_ENV: 'production', ALLOWED_ROOMS: room, TURN_PROVIDER: 'coturn',
    TURN_URLS: 'turn:relay.example.test:3478', TURN_SECRET: 's'.repeat(32),
    TURN_PROVIDER_TIMEOUT_MS: '5000', AUTH_TIMEOUT_MS: '5000',
  })).toThrow('TURN_PROVIDER_TIMEOUT_MS must be lower than AUTH_TIMEOUT_MS');

  const config = loadServiceConfig({
    NODE_ENV: 'production', ALLOWED_ROOMS: room, TURN_PROVIDER: 'cloudflare',
    CLOUDFLARE_TURN_KEY_ID: 'k'.repeat(32), CLOUDFLARE_TURN_KEY_API_TOKEN: 't'.repeat(64),
  });
  expect(config.turnProvider?.kind).toBe('cloudflare');
  expect(config.allowedRooms).toEqual([room]);
});

test('production configuration accepts an explicit private file approval control', () => {
  const approvedPath = privateFile('approved');
  const config = loadServiceConfig({
    NODE_ENV: 'production', APPROVED_ROOMS_FILE: approvedPath, TURN_PROVIDER: 'cloudflare',
    CLOUDFLARE_TURN_KEY_ID: 'k'.repeat(32), CLOUDFLARE_TURN_KEY_API_TOKEN: 't'.repeat(64),
  });
  expect(config.roomApproval?.isApproved(room)).toBe(false);
  expect(config.approvalAuditMs).toBe(1000);
  expect(() => loadServiceConfig({ APPROVAL_AUDIT_INTERVAL_MS: '99' })).toThrow('APPROVAL_AUDIT_INTERVAL_MS');
});
