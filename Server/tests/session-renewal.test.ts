import { afterEach, expect, test } from 'bun:test';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadServiceConfig } from '../src/config';
import { createFileRoomApproval, mutateApprovedRooms, writeApprovedRooms } from '../src/rooms';
import { RENEWAL_FEATURE, createService, digest, type ServiceConfig } from '../src/server';
import type { IceServer, TurnCredentialProvider } from '../src/turn';
import { FakeClock } from './fake-clock';

const hostToken = 'a'.repeat(64), clientToken = 'b'.repeat(64), room = digest(hostToken);
const minute = 60_000;
const lease = 30 * minute;
const renewing = [RENEWAL_FEATURE];

const instances: ReturnType<typeof createService>[] = [];
const directories: string[] = [];
afterEach(async () => {
  await Promise.all(instances.map(app => app.stop(100))); instances.length = 0;
  for (const path of directories) rmSync(path, { recursive: true, force: true });
  directories.length = 0;
});

function start(clock: FakeClock, config: ServiceConfig = {}) {
  const app = createService({ port: 0, clock, maxRoomLifetimeMs: lease, ...config });
  instances.push(app);
  return app;
}

function peer(app: ReturnType<typeof start>) {
  const ws = new WebSocket(`ws://127.0.0.1:${app.server.port}/signal`);
  const messages: any[] = [], waiters: ((value: any) => void)[] = [];
  ws.onmessage = event => {
    const value = JSON.parse(String(event.data)), waiter = waiters.shift();
    if (waiter) waiter(value); else messages.push(value);
  };
  const open = new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = reject; });
  const closed = new Promise<CloseEvent>(resolve => { ws.onclose = resolve; });
  const next = () => messages.length ? Promise.resolve(messages.shift()) : new Promise<any>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('message timeout')), 2000);
    waiters.push(value => { clearTimeout(timer); resolve(value); });
  });
  return { ws, open, next, messages, closed, send: (value: unknown) => ws.send(JSON.stringify(value)) };
}

const register = (role: 'host' | 'client', features?: string[]) => ({
  type: 'register', version: 1, role, room, token: role === 'host' ? hostToken : clientToken,
  clientTokenHash: digest(clientToken), ...(features ? { features } : {}),
});

async function connect(app: ReturnType<typeof start>, role: 'host' | 'client', features?: string[]) {
  const p = peer(app);
  await p.open;
  p.send(register(role, features));
  const registered = await p.next();
  const ice = await p.next();
  return Object.assign(p, { registered, ice });
}

async function pair(app: ReturnType<typeof start>, hostFeatures?: string[], clientFeatures?: string[]) {
  const host = await connect(app, 'host', hostFeatures);
  const client = await connect(app, 'client', clientFeatures);
  expect((await host.next()).online).toBe(true);
  expect((await client.next()).online).toBe(true);
  return { host, client };
}

function recordingProvider(clock: FakeClock, ttlSeconds = 3600) {
  const issued: { role: string; username: string; expiresAt: number }[] = [];
  const revoked: string[] = [];
  let failing = false;
  const provider: TurnCredentialProvider = {
    kind: 'cloudflare',
    ttlSeconds,
    issue: async ({ role }) => {
      if (failing) throw new Error('provider down');
      const username = `${role}-${issued.length + 1}`;
      issued.push({ role, username, expiresAt: clock.now() + ttlSeconds * 1000 });
      return [{ urls: ['turn:relay.example.test:3478'], username, credential: `credential-${username}` }];
    },
    revoke: async servers => { for (const server of servers) revoked.push(server.username!); },
  };
  return { provider, issued, revoked, setFailing: (value: boolean) => { failing = value; } };
}

function approvals(rooms: string[]) {
  const directory = mkdtempSync(join(tmpdir(), 'pocketdesk-renewal-'));
  directories.push(directory);
  const approvedPath = join(directory, 'approved');
  writeFileSync(approvedPath, '', { mode: 0o600 });
  chmodSync(approvedPath, 0o600);
  writeApprovedRooms(approvedPath, rooms);
  return { approvedPath, approval: createFileRoomApproval({ approvedPath }) };
}

const holdsUsername = (message: { servers?: IceServer[] }) => message.servers?.find(server => server.username)?.username as string;

test('a peer that does not renew keeps the original fixed lifetime with unchanged messages', async () => {
  const clock = new FakeClock(), app = start(clock);
  const { host, client } = await pair(app);
  expect(host.registered).toEqual({ type: 'registered', role: 'host' });
  expect(host.ice).toEqual({ type: 'ice', servers: [] });

  await clock.advance(lease - 1);
  expect(app.roomCount()).toBe(1);
  await clock.advance(1);
  const [hostClose, clientClose] = await Promise.all([host.closed, client.closed]);
  expect(hostClose.reason).toBe('room_lifetime_reached');
  expect(clientClose.reason).toBe('host_disconnected');
  expect(app.roomCount()).toBe(0);
});

test('renewing peers keep the room past 30, 60 and 120 minutes, and it still ends when they stop', async () => {
  const clock = new FakeClock(), app = start(clock);
  const { host, client } = await pair(app, renewing, renewing);
  expect(host.registered).toEqual({ type: 'registered', role: 'host', renew: { version: 1, leaseSeconds: 1800, renewAfterSeconds: 900 } });
  expect(client.registered.renew).toEqual({ version: 1, leaseSeconds: 1800, renewAfterSeconds: 900 });
  expect(host.ice).toEqual({ type: 'ice', servers: [] });

  const checkpoints = new Set([30, 60, 120]);
  const reached: number[] = [];
  for (let elapsed = 15; elapsed <= 135; elapsed += 15) {
    await clock.advance(15 * minute);
    host.send({ type: 'renew' });
    expect(await host.next()).toEqual({ type: 'renewed', leaseSeconds: 1800, renewAfterSeconds: 900 });
    expect(app.roomCount()).toBe(1);
    if (checkpoints.has(elapsed)) {
      expect([host.ws.readyState, client.ws.readyState]).toEqual([WebSocket.OPEN, WebSocket.OPEN]);
      reached.push(elapsed);
    }
  }
  expect(reached).toEqual([30, 60, 120]);

  await clock.advance(lease);
  expect((await host.closed).reason).toBe('room_lifetime_reached');
  expect((await client.closed).reason).toBe('host_disconnected');
  expect(app.roomCount()).toBe(0);
});

test('an idle Mac with no phone keeps its registration for hours by renewing', async () => {
  const clock = new FakeClock(), app = start(clock);
  const host = await connect(app, 'host', renewing);
  for (let elapsed = 15; elapsed <= 240; elapsed += 15) {
    await clock.advance(15 * minute);
    host.send({ type: 'renew' });
    expect((await host.next()).type).toBe('renewed');
  }
  expect(app.roomCount()).toBe(1);
  expect(host.ws.readyState).toBe(WebSocket.OPEN);
});

test('a renewal in the last millisecond extends the lease from that moment', async () => {
  const clock = new FakeClock(), app = start(clock);
  const host = await connect(app, 'host', renewing);
  await clock.advance(lease - 1);
  host.send({ type: 'renew' });
  expect((await host.next()).type).toBe('renewed');
  await clock.advance(lease - 1);
  expect(app.roomCount()).toBe(1);
  await clock.advance(1);
  expect((await host.closed).reason).toBe('room_lifetime_reached');
});

test('a renewal after the lease ran out is refused even when the expiry timer has not fired yet', async () => {
  const clock = new FakeClock(), app = start(clock);
  const host = await connect(app, 'host', renewing);
  clock.stall(lease);
  host.send({ type: 'renew' });
  const closed = await host.closed;
  expect(closed.reason).toBe('room_lifetime_reached');
  expect(host.messages.some(message => message.type === 'renewed')).toBe(false);
  expect(app.roomCount()).toBe(0);
});

test('a renewal one millisecond before a stalled event loop reaches the boundary is still honoured', async () => {
  const clock = new FakeClock(), app = start(clock);
  const host = await connect(app, 'host', renewing);
  clock.stall(lease - 1);
  host.send({ type: 'renew' });
  expect((await host.next()).type).toBe('renewed');
  expect(app.roomCount()).toBe(1);
});

test('the phone alone keeps a room alive for a Mac app that does not renew', async () => {
  const clock = new FakeClock(), app = start(clock);
  const { host, client } = await pair(app, undefined, renewing);
  expect(host.registered).toEqual({ type: 'registered', role: 'host' });
  for (let elapsed = 15; elapsed <= 120; elapsed += 15) {
    await clock.advance(15 * minute);
    client.send({ type: 'renew' });
    expect((await client.next()).type).toBe('renewed');
  }
  expect(app.roomCount()).toBe(1);
  expect(host.messages).toEqual([]);
  await clock.advance(lease);
  expect((await host.closed).reason).toBe('room_lifetime_reached');
});

test('renewal is negotiated: a peer that did not ask for it cannot send renew', async () => {
  const clock = new FakeClock(), app = start(clock);
  const legacy = await connect(app, 'host');
  legacy.send({ type: 'renew' });
  expect(await legacy.next()).toEqual({ type: 'error', code: 'invalid_message' });
  expect((await legacy.closed).code).toBe(1008);
});

test('with renewal switched off the service answers every peer like the original service', async () => {
  const clock = new FakeClock(), app = start(clock, { sessionRenewal: false });
  const host = await connect(app, 'host', renewing);
  expect(host.registered).toEqual({ type: 'registered', role: 'host' });
  host.send({ type: 'renew' });
  expect(await host.next()).toEqual({ type: 'error', code: 'invalid_message' });
  await host.closed;

  const second = start(new FakeClock(), { sessionRenewal: false });
  const other = await connect(second, 'host', renewing);
  expect(other.registered).toEqual({ type: 'registered', role: 'host' });
});

test('renew must be exactly the type and nothing else', async () => {
  const clock = new FakeClock(), app = start(clock);
  const host = await connect(app, 'host', renewing);
  host.send({ type: 'renew', extra: 1 });
  expect(await host.next()).toEqual({ type: 'error', code: 'invalid_message' });
  await host.closed;
});

test('feature lists are validated and unknown features are ignored', async () => {
  const clock = new FakeClock(), app = start(clock);
  for (const bad of ['renew.1', ['RENEW'], [7], Array.from({ length: 9 }, (_, index) => `f${index}`), ['x'.repeat(33)]]) {
    const p = peer(app);
    await p.open;
    p.send({ ...register('host'), features: bad });
    expect((await p.next()).code).toBe('invalid_registration');
  }
  const future = await connect(app, 'host', ['future.9']);
  expect(future.registered).toEqual({ type: 'registered', role: 'host' });
});

test('relay credentials are refreshed a third of the way through their life and never used after expiry across three hours', async () => {
  const clock = new FakeClock(), relay = recordingProvider(clock, 3600);
  const app = start(clock, { turnProvider: relay.provider });
  const { host, client } = await pair(app, renewing, renewing);
  expect(host.registered.renew).toEqual({ version: 1, leaseSeconds: 1800, renewAfterSeconds: 900, credentialSeconds: 3600 });
  expect(client.registered.renew).toEqual({ version: 1, leaseSeconds: 1800, renewAfterSeconds: 900, credentialSeconds: 3600 });

  const sides = [
    { name: 'host', p: host, held: holdsUsername(host.ice), nextAt: clock.now() + 900_000, lastIssue: clock.now() },
    { name: 'client', p: client, held: holdsUsername(client.ice), nextAt: clock.now() + 900_000, lastIssue: clock.now() },
  ];
  const expiryOf = (username: string) => relay.issued.find(item => item.username === username)!.expiresAt;
  const gaps: number[] = [];
  const checked: number[] = [];
  const startedAt = clock.now();
  const end = startedAt + 180 * minute;
  while (clock.now() < end) {
    await clock.advance(minute);
    for (const side of sides) {
      if (clock.now() < side.nextAt) continue;
      side.p.send({ type: 'renew' });
      const reply = await side.p.next();
      expect(reply.type).toBe('renewed');
      expect(reply.code).toBeUndefined();
      if (reply.servers) {
        side.held = holdsUsername(reply);
        gaps.push(clock.now() - side.lastIssue);
        side.lastIssue = clock.now();
        expect(reply.credentialSeconds).toBe(3600);
      }
      side.nextAt = clock.now() + reply.renewAfterSeconds * 1000;
    }
    for (const side of sides) expect(expiryOf(side.held)).toBeGreaterThan(clock.now());
    expect(app.roomCount()).toBe(1);
    const elapsedMinutes = Math.round((clock.now() - startedAt) / minute);
    if ([30, 60, 120, 180].includes(elapsedMinutes)) checked.push(elapsedMinutes);
  }
  expect(checked).toEqual([30, 60, 120, 180]);
  expect(relay.revoked).toEqual([]);
  expect(Math.max(...gaps)).toBeLessThanOrEqual(22 * minute);
  expect(Math.min(...gaps)).toBeGreaterThanOrEqual(20 * minute);
  for (const role of ['host', 'client']) {
    const count = relay.issued.filter(item => item.role === role).length;
    expect(count).toBeGreaterThanOrEqual(9);
    expect(count).toBeLessThanOrEqual(11);
  }

  const hostClosed = host.closed;
  host.ws.close();
  await hostClosed;
  expect((await client.closed).reason).toBe('host_disconnected');
  await Bun.sleep(20);
  const unexpired = relay.issued.filter(item => item.expiresAt > clock.now()).map(item => item.username);
  expect(unexpired.length).toBeGreaterThanOrEqual(6);
  for (const username of unexpired) expect(relay.revoked).toContain(username);
  for (const username of relay.revoked) expect(relay.issued.some(item => item.username === username)).toBe(true);
});

test('a peer that never renews still loses the room before its credentials can expire', async () => {
  const clock = new FakeClock(), relay = recordingProvider(clock, 3600);
  const app = start(clock, { turnProvider: relay.provider });
  const { host, client } = await pair(app);
  await clock.advance(lease);
  await Promise.all([host.closed, client.closed]);
  expect(clock.now() - relay.issued[0].expiresAt).toBeLessThan(0);
  await Bun.sleep(20);
  expect(relay.revoked.sort()).toEqual(['client-2', 'host-1']);
});

test('a provider outage on refresh keeps the room and lease, and refresh works again after recovery', async () => {
  const clock = new FakeClock(), relay = recordingProvider(clock, 3600);
  const app = start(clock, { turnProvider: relay.provider });
  const { host } = await pair(app, renewing, renewing);
  await clock.advance(20 * minute);
  relay.setFailing(true);
  host.send({ type: 'renew' });
  expect(await host.next()).toEqual({ type: 'renewed', leaseSeconds: 1800, renewAfterSeconds: 30, code: 'relay_unavailable' });
  expect(app.roomCount()).toBe(1);

  await clock.advance(30_000);
  relay.setFailing(false);
  host.send({ type: 'renew' });
  const recovered = await host.next();
  expect(recovered.code).toBeUndefined();
  expect(recovered.servers[0].username).toBe('host-3');
  expect(recovered.credentialSeconds).toBe(3600);

  await clock.advance(lease - 1);
  expect(app.roomCount()).toBe(1);
});

test('renewals count against the credential issuance limit and report rate_limited without dropping the room', async () => {
  const clock = new FakeClock(), relay = recordingProvider(clock, 3600);
  const app = start(clock, { turnProvider: relay.provider, credentialIssuesPerMinute: 1 });
  const host = await connect(app, 'host', renewing);
  await clock.advance(61_000);
  const client = await connect(app, 'client', renewing);
  expect((await host.next()).online).toBe(true);
  expect((await client.next()).online).toBe(true);

  await clock.advance(1209_000);
  host.send({ type: 'renew' });
  expect((await host.next()).servers).toBeDefined();
  client.send({ type: 'renew' });
  const limited = await client.next();
  expect(limited).toMatchObject({ type: 'renewed', code: 'rate_limited', renewAfterSeconds: 30 });
  expect(limited.servers).toBeUndefined();
  expect(app.roomCount()).toBe(1);

  await clock.advance(61_000);
  client.send({ type: 'renew' });
  expect((await client.next()).servers).toBeDefined();
});

test('revocation ends a renewing session at once and a renewal cannot revive it', async () => {
  const clock = new FakeClock(), relay = recordingProvider(clock, 60);
  const { approvedPath, approval } = approvals([room]);
  const app = start(clock, { turnProvider: relay.provider, roomApproval: approval, approvalAuditMs: 1000 });
  const { host, client } = await pair(app, renewing, renewing);
  await clock.advance(25_000);
  const issuedBefore = relay.issued.length;

  mutateApprovedRooms(approvedPath, current => current.filter(item => item !== room));
  host.send({ type: 'renew' });
  const [hostClose, clientClose] = await Promise.all([host.closed, client.closed]);
  expect([hostClose.code, hostClose.reason]).toEqual([1008, 'room_approval_revoked']);
  expect([clientClose.code, clientClose.reason]).toEqual([1008, 'room_approval_revoked']);
  expect(host.messages.some(message => message.type === 'renewed')).toBe(false);
  expect(relay.issued.length).toBe(issuedBefore);
  expect(app.roomCount()).toBe(0);
  await Bun.sleep(20);
  expect(relay.revoked.sort()).toEqual(['client-2', 'host-1']);
});

test('the approval audit still ends a renewing session within its interval', async () => {
  const clock = new FakeClock();
  const { approvedPath, approval } = approvals([room]);
  const app = start(clock, { roomApproval: approval, approvalAuditMs: 1000 });
  const { host, client } = await pair(app, renewing, renewing);
  await clock.advance(10 * minute);
  host.send({ type: 'renew' });
  expect((await host.next()).type).toBe('renewed');

  mutateApprovedRooms(approvedPath, current => current.filter(item => item !== room));
  await clock.advance(1000);
  const [hostClose, clientClose] = await Promise.all([host.closed, client.closed]);
  expect([hostClose.code, hostClose.reason]).toEqual([1008, 'room_approval_revoked']);
  expect(clientClose.code).toBe(1008);
  expect(app.roomCount()).toBe(0);
});

test('Stop Sharing revokes every live credential immediately and ends the phone session', async () => {
  const clock = new FakeClock(), relay = recordingProvider(clock, 3600);
  const app = start(clock, { turnProvider: relay.provider });
  const { host, client } = await pair(app, renewing, renewing);
  await clock.advance(20 * minute);
  host.send({ type: 'renew' });
  expect((await host.next()).servers).toBeDefined();
  expect(relay.revoked).toEqual([]);

  host.ws.close();
  expect((await client.closed).reason).toBe('host_disconnected');
  await Bun.sleep(20);
  expect(relay.revoked.sort()).toEqual(['client-2', 'host-1', 'host-3']);
  expect(app.roomCount()).toBe(0);
});

test('credentials whose renewal finished after the peer left are revoked instead of delivered', async () => {
  const clock = new FakeClock();
  const revoked: string[] = [];
  let resolveIssue!: (servers: IceServer[]) => void;
  let refreshStarted!: () => void;
  const started = new Promise<void>(resolve => { refreshStarted = resolve; });
  let calls = 0;
  const app = start(clock, {
    turnProvider: {
      kind: 'cloudflare',
      ttlSeconds: 3600,
      issue: () => {
        calls += 1;
        if (calls === 1) return Promise.resolve([{ urls: ['turn:relay.example.test'], username: 'initial', credential: 'c' }]);
        refreshStarted();
        return new Promise(resolve => { resolveIssue = resolve; });
      },
      revoke: async servers => { revoked.push(servers[0].username!); },
    },
  });
  const host = await connect(app, 'host', renewing);
  await clock.advance(20 * minute);
  host.send({ type: 'renew' });
  await started;
  host.ws.close();
  await host.closed;
  resolveIssue([{ urls: ['turn:relay.example.test'], username: 'late', credential: 'c' }]);
  await Bun.sleep(20);
  expect(revoked.sort()).toEqual(['initial', 'late']);
  expect(app.roomCount()).toBe(0);
});

test('a second renewal while one is issuing is answered as pending and issues nothing', async () => {
  const clock = new FakeClock();
  let calls = 0;
  let release!: (servers: IceServer[]) => void;
  let refreshStarted!: () => void;
  const started = new Promise<void>(resolve => { refreshStarted = resolve; });
  const app = start(clock, {
    turnProvider: {
      kind: 'cloudflare',
      ttlSeconds: 3600,
      issue: () => {
        calls += 1;
        if (calls === 1) return Promise.resolve([{ urls: ['turn:relay.example.test'], username: 'initial', credential: 'c' }]);
        refreshStarted();
        return new Promise(resolve => { release = resolve; });
      },
    },
  });
  const host = await connect(app, 'host', renewing);
  await clock.advance(20 * minute);
  host.send({ type: 'renew' });
  await started;
  host.send({ type: 'renew' });
  expect(await host.next()).toMatchObject({ type: 'renewed', code: 'renewal_pending' });
  release([{ urls: ['turn:relay.example.test'], username: 'refreshed', credential: 'c' }]);
  const done = await host.next();
  expect(done.servers[0].username).toBe('refreshed');
  expect(calls).toBe(2);
});

test('readiness reports whether renewal is on and how often it has run', async () => {
  const clock = new FakeClock(), relay = recordingProvider(clock, 3600);
  const app = start(clock, { turnProvider: relay.provider });
  const { host } = await pair(app, renewing, renewing);
  await clock.advance(20 * minute);
  host.send({ type: 'renew' });
  await host.next();
  const body = await (await fetch(`http://127.0.0.1:${app.server.port}/ready`)).json() as any;
  expect(body.renewal).toEqual({ enabled: true, leaseSeconds: 1800, renewals: 1, credentialRefreshes: 1 });
  const off = start(new FakeClock(), { sessionRenewal: false });
  expect(((await (await fetch(`http://127.0.0.1:${off.server.port}/ready`)).json()) as any).renewal.enabled).toBe(false);
});

test('configuration exposes the renewal switch and keeps the lease below the credential lifetime', () => {
  const base = { NODE_ENV: 'development' };
  expect(loadServiceConfig(base).sessionRenewal).toBe(true);
  expect(loadServiceConfig({ ...base, SESSION_RENEWAL: '0' }).sessionRenewal).toBe(false);
  expect(loadServiceConfig({ ...base, SESSION_RENEWAL: 'true' }).sessionRenewal).toBe(true);
  expect(() => loadServiceConfig({ ...base, SESSION_RENEWAL: 'yes' })).toThrow('SESSION_RENEWAL must be 0, 1, true, or false');
  expect(loadServiceConfig({ ...base, TURN_CREDENTIAL_TTL_SECONDS: '7200' }).credentialTTLSeconds).toBe(7200);
  expect(() => loadServiceConfig({ ...base, TURN_CREDENTIAL_TTL_SECONDS: '600', ROOM_LIFETIME_SECONDS: '600' }))
    .toThrow('ROOM_LIFETIME_SECONDS must be lower than TURN_CREDENTIAL_TTL_SECONDS');
});
