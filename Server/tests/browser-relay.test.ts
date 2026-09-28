import { afterEach, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBrowserService, type BrowserServiceConfig } from '../src/browser/service';
import { createBrowserRelay } from '../src/browser/relay';
import type { IceServer, TurnCredentialProvider } from '../src/turn';

const hostToken = 'a'.repeat(64);
const hostID = createHash('sha256').update(hostToken).digest('hex');
const peerID = 'b'.repeat(64);
const session = 'c'.repeat(64);
const ticket = 'd'.repeat(64);

type App = ReturnType<typeof createBrowserService>;
const instances: App[] = [];
const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(instances.map(instance => instance.stop()));
  instances.length = 0;
  for (const directory of temporaryDirectories) rmSync(directory, { recursive: true, force: true });
  temporaryDirectories.length = 0;
});

function staticFixture() {
  const root = mkdtempSync(join(tmpdir(), 'pocketdesk-browser-relay-static-'));
  temporaryDirectories.push(root);
  return root;
}

function setup(config: BrowserServiceConfig = {}) {
  const app = createBrowserService({ staticRoot: staticFixture(), ...config });
  instances.push(app);
  return app;
}

function socket(app: App, path: '/browser-host' | '/browser-signal', origin?: string) {
  const options = origin ? { headers: { Origin: origin } } : undefined;
  const ws = new WebSocket(`ws://127.0.0.1:${app.port}${path}`, options);
  const messages: unknown[] = [];
  const waiters: Array<(value: any) => void> = [];
  ws.onmessage = event => {
    const value = JSON.parse(String(event.data));
    const waiter = waiters.shift();
    if (waiter) waiter(value); else messages.push(value);
  };
  const open = new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = reject; });
  const next = (timeoutMs = 2_000) => messages.length ? Promise.resolve(messages.shift()) : new Promise<any>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('message timeout')), timeoutMs);
    waiters.push(value => { clearTimeout(timer); resolve(value); });
  });
  return { ws, open, next, messages, send: (value: unknown) => ws.send(JSON.stringify(value)) };
}

async function connectHost(app: App, id = hostID, token = hostToken) {
  const host = socket(app, '/browser-host');
  await host.open;
  host.send({ type: 'host', hostID: id, token });
  expect(await host.next()).toEqual({ type: 'registered', hostID: id });
  return host;
}

function installTicket(host: ReturnType<typeof socket>, value = ticket, targetSession = session, ttl = 1_000) {
  host.send({ type: 'ticket', ticket: value, session: targetSession, expires: String(Date.now() + ttl), peerID });
}

function connectBrowser(app: App, value = ticket, targetSession = session, id = hostID) {
  return (async () => {
    const browser = socket(app, '/browser-signal', `http://127.0.0.1:${app.port}`);
    await browser.open;
    browser.send({ type: 'browser', hostID: id, session: targetSession, ticket: value });
    return browser;
  })();
}

function makeHost(seed: string) {
  const token = seed.repeat(64).slice(0, 64);
  const id = createHash('sha256').update(token).digest('hex');
  return { token, id };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

function mockProvider(overrides: Partial<TurnCredentialProvider> & { issue: TurnCredentialProvider['issue'] }): TurnCredentialProvider {
  return { kind: 'coturn', ...overrides };
}

test('createBrowserRelay refuses testForceRelay without a provider', () => {
  expect(() => createBrowserRelay({ testForceRelay: true })).toThrow('testForceRelay requires a relay provider');
  expect(() => createBrowserRelay({ testForceRelay: true, provider: mockProvider({ issue: async () => [] }) })).not.toThrow();
});

test('createBrowserService refuses testForceRelay without a provider', () => {
  expect(() => createBrowserService({ testForceRelay: true, staticRoot: staticFixture() })).toThrow(
    'testForceRelay requires a relay provider',
  );
});

test('no relay configured still issues STUN-only servers with policy all', async () => {
  const app = setup({ stunURLs: ['stun:stun.example.test:3478'] });
  const host = await connectHost(app);
  installTicket(host);
  const browser = await connectBrowser(app);
  expect(await host.next()).toEqual({ type: 'ice', session, servers: [{ urls: ['stun:stun.example.test:3478'] }], policy: 'all' });
  expect(await host.next()).toEqual({ type: 'joined', session });
  expect(await browser.next()).toEqual({ type: 'registered', session });
  expect(await browser.next()).toEqual({ type: 'ice', servers: [{ urls: ['stun:stun.example.test:3478'] }], policy: 'all' });
});

test('testForceRelay sends policy relay to both sides', async () => {
  const provider = mockProvider({
    issue: async ({ role }) => [{ urls: ['turn:relay.example.test'], username: role, credential: 'secret' }],
  });
  const app = setup({ turnProvider: provider, testForceRelay: true });
  const host = await connectHost(app);
  installTicket(host);
  const browser = await connectBrowser(app);
  const hostIce = await host.next();
  expect(hostIce).toEqual({
    type: 'ice', session, policy: 'relay', servers: [{ urls: ['turn:relay.example.test'], username: 'host', credential: 'secret' }],
  });
  await host.next();
  await browser.next();
  const browserIce = await browser.next();
  expect(browserIce).toEqual({
    type: 'ice', policy: 'relay', servers: [{ urls: ['turn:relay.example.test'], username: 'client', credential: 'secret' }],
  });
  // Credentials never leak outside the two WS ice messages.
  expect(JSON.stringify(hostIce)).not.toContain('client');
});

test('issuance never happens before admission: GET and browser-api never trigger the provider', async () => {
  let calls = 0;
  const provider = mockProvider({ issue: async () => { calls += 1; return [{ urls: ['turn:relay.example.test'], username: 'u', credential: 'c' }]; } });
  const app = setup({ turnProvider: provider });
  const host = await connectHost(app);
  const origin = `http://127.0.0.1:${app.port}`;
  await fetch(origin);
  const pending = fetch(`${origin}/browser-api/${hostID}/challenge`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin },
    body: JSON.stringify({ peerID, nonce: 'e'.repeat(64), mode: 'view' }),
  });
  const rpc = await host.next();
  host.send({ type: 'response', id: rpc.id, body: { fields: ['ok'], signature: 'sig' } });
  await pending;
  expect(calls).toBe(0);
  installTicket(host);
  await connectBrowser(app);
  await host.next(); await host.next();
  expect(calls).toBe(2);
});

test('relay_unavailable on provider failure ends the session for both sides', async () => {
  const provider = mockProvider({ issue: async () => { throw new Error('provider down'); } });
  const app = setup({ turnProvider: provider });
  const host = await connectHost(app);
  installTicket(host);
  const browser = await connectBrowser(app);
  expect(await host.next()).toEqual({ type: 'end', session });
  expect(await browser.next()).toEqual({ type: 'error', code: 'relay_unavailable' });
});

test('relay_unavailable on provider timeout also revokes nothing prematurely and ends cleanly', async () => {
  const stalled = deferred<IceServer[]>();
  let revoked: IceServer[] | undefined;
  const provider = mockProvider({
    issue: async () => stalled.promise,
    revoke: async servers => { revoked = servers; },
  });
  const app = setup({ turnProvider: provider, relayTimeoutMs: 250 });
  const host = await connectHost(app);
  installTicket(host);
  const browser = await connectBrowser(app);
  expect(await host.next()).toEqual({ type: 'end', session });
  expect(await browser.next()).toEqual({ type: 'error', code: 'relay_unavailable' });
  stalled.resolve([{ urls: ['turn:relay.example.test'], username: 'late', credential: 'credential' }]);
  await Bun.sleep(20);
  expect(revoked?.[0]?.username).toBe('late');
});

test('startup refuses testForceRelay without a provider (service-level)', () => {
  expect(() => createBrowserService({ staticRoot: staticFixture(), testForceRelay: true, turnProvider: undefined })).toThrow();
});

test('revocation happens exactly once per role across every end path', async () => {
  const revocations: string[] = [];
  const provider = mockProvider({
    issue: async ({ role }) => [{ urls: ['turn:relay.example.test'], username: role, credential: 'c' }],
    revoke: async servers => { for (const server of servers) revocations.push(server.username!); },
  });

  async function admittedSession(seed: string) {
    const { id, token } = makeHost(seed);
    const app = setup({ turnProvider: provider });
    const host = await connectHost(app, id, token);
    installTicket(host, ticket, session);
    const browser = await connectBrowser(app, ticket, session, id);
    await host.next(); await host.next(); await browser.next(); await browser.next();
    return { app, host, browser };
  }

  // host end
  {
    const { host } = await admittedSession('1');
    host.send({ type: 'end', session });
    await Bun.sleep(10);
    host.send({ type: 'end', session });
    await Bun.sleep(10);
  }
  expect(revocations.filter(u => u === 'host').length).toBe(1);
  expect(revocations.filter(u => u === 'client').length).toBe(1);

  // host stop
  revocations.length = 0;
  {
    const { host } = await admittedSession('2');
    host.send({ type: 'stop' });
    await Bun.sleep(10);
    host.send({ type: 'stop' });
    await Bun.sleep(10);
  }
  expect(revocations.filter(u => u === 'host').length).toBe(1);
  expect(revocations.filter(u => u === 'client').length).toBe(1);

  // browser end
  revocations.length = 0;
  {
    const { browser } = await admittedSession('3');
    browser.send({ type: 'end', session });
    await Bun.sleep(10);
  }
  expect(revocations.filter(u => u === 'host').length).toBe(1);
  expect(revocations.filter(u => u === 'client').length).toBe(1);

  // browser ws close
  revocations.length = 0;
  {
    const { browser } = await admittedSession('4');
    browser.ws.close();
    await Bun.sleep(10);
  }
  expect(revocations.filter(u => u === 'host').length).toBe(1);
  expect(revocations.filter(u => u === 'client').length).toBe(1);

  // host ws close
  revocations.length = 0;
  {
    const { host } = await admittedSession('5');
    host.ws.close();
    await Bun.sleep(10);
  }
  expect(revocations.filter(u => u === 'host').length).toBe(1);
  expect(revocations.filter(u => u === 'client').length).toBe(1);

  // service.stop() drain
  revocations.length = 0;
  {
    const { app } = await admittedSession('6');
    await app.stop();
  }
  expect(revocations.filter(u => u === 'host').length).toBe(1);
  expect(revocations.filter(u => u === 'client').length).toBe(1);
});

test('late issuance after session end is revoked immediately and not double-revoked at teardown', async () => {
  const stalled = deferred<IceServer[]>();
  const revoked: string[] = [];
  const provider = mockProvider({
    issue: async ({ role }) => role === 'client' ? stalled.promise : [{ urls: ['turn:relay.example.test'], username: 'host', credential: 'c' }],
    revoke: async servers => { for (const server of servers) revoked.push(server.username!); },
  });
  const app = setup({ turnProvider: provider });
  const host = await connectHost(app);
  installTicket(host);
  const browser = await connectBrowser(app);
  await host.next(); await host.next();
  // Browser's issuance is now pending. Close the host so the session tears down mid-admission.
  host.ws.close();
  await Bun.sleep(10);
  expect(revoked).toEqual(['host']);
  stalled.resolve([{ urls: ['turn:relay.example.test'], username: 'late-client', credential: 'c' }]);
  await Bun.sleep(10);
  expect(revoked.sort()).toEqual(['host', 'late-client']);
});

test('issuance cap is enforced', async () => {
  const provider = mockProvider({ issue: async ({ role }) => [{ urls: ['turn:relay.example.test'], username: role, credential: 'c' }] });
  // A full admission spends two issuances (host role + browser role); a cap of two allows
  // exactly one session before the next session's very first (host) issuance is refused.
  const app = setup({ turnProvider: provider, relayIssuesPerMinute: 2 });
  {
    const { id, token } = makeHost('0');
    const host = await connectHost(app, id, token);
    const localSession = '0'.repeat(64);
    installTicket(host, ticket, localSession);
    await connectBrowser(app, ticket, localSession, id);
    expect((await host.next()).type).toBe('ice');
  }
  const { id, token } = makeHost('9');
  const host = await connectHost(app, id, token);
  const localSession = '9'.repeat(64);
  installTicket(host, ticket, localSession);
  await connectBrowser(app, ticket, localSession, id);
  expect(await host.next()).toEqual({ type: 'end', session: localSession });
});

test('devRoutes false hides probe/fixtures/diagnostics while admission routes still work', async () => {
  const root = staticFixture();
  const { mkdirSync, writeFileSync: write } = require('node:fs') as typeof import('node:fs');
  mkdirSync(join(root, 'BrowserClient'), { recursive: true });
  mkdirSync(join(root, 'BrowserProbe'), { recursive: true });
  mkdirSync(join(root, 'BrowserFixtures'), { recursive: true });
  write(join(root, 'BrowserClient/index.html'), '<!doctype html>');
  write(join(root, 'BrowserProbe/index.html'), '<!doctype html>');
  write(join(root, 'BrowserFixtures/code-scene.js'), 'export const frame = 1;');
  const diagnosticsDir = mkdtempSync(join(tmpdir(), 'pocketdesk-browser-relay-diag-'));
  temporaryDirectories.push(diagnosticsDir);
  const app = createBrowserService({ staticRoot: root, devRoutes: false, diagnosticsDir });
  instances.push(app);
  const origin = `http://127.0.0.1:${app.port}`;
  expect((await fetch(`${origin}/probe/`)).status).toBe(404);
  expect((await fetch(`${origin}/fixtures/code-scene.js`)).status).toBe(404);
  expect((await fetch(`${origin}/api/diagnostics`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin }, body: '{}',
  })).status).toBe(404);
  expect((await fetch(`${origin}/`)).status).toBe(200);

  const host = await connectHost(app);
  installTicket(host);
  const browser = await connectBrowser(app);
  expect(await host.next()).toEqual({ type: 'ice', session, servers: [], policy: 'all' });
  expect(await host.next()).toEqual({ type: 'joined', session });
  expect(await browser.next()).toEqual({ type: 'registered', session });
  expect(await browser.next()).toEqual({ type: 'ice', servers: [], policy: 'all' });
});

test('credentials never appear in HTTP response bodies', async () => {
  const provider = mockProvider({
    issue: async ({ role }) => [{ urls: ['turn:relay.example.test'], username: role, credential: 'top-secret' }],
  });
  const app = setup({ turnProvider: provider });
  const host = await connectHost(app);
  const origin = `http://127.0.0.1:${app.port}`;
  const pending = fetch(`${origin}/browser-api/${hostID}/challenge`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin },
    body: JSON.stringify({ peerID, nonce: 'e'.repeat(64), mode: 'view' }),
  });
  const rpc = await host.next();
  host.send({ type: 'response', id: rpc.id, body: { fields: ['ok'], signature: 'sig' } });
  const response = await pending;
  const text = await response.text();
  expect(text).not.toContain('top-secret');
});
