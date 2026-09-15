import { afterEach, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBrowserService, type BrowserServiceConfig } from '../src/browser/service';

const hostToken = 'a'.repeat(64);
const hostID = createHash('sha256').update(hostToken).digest('hex');
const peerID = 'b'.repeat(64);
const session = 'c'.repeat(64);
const ticket = 'd'.repeat(64);
const nonce = 'e'.repeat(64);
const enrollmentNonce = Buffer.alloc(12, 5).toString('base64');
const enrollmentPayload = Buffer.alloc(32, 6).toString('base64');
const publicKey = Buffer.concat([Buffer.from([4]), Buffer.alloc(64, 7)]).toString('base64');
const signature = Buffer.alloc(64, 9).toString('base64');

type App = ReturnType<typeof createBrowserService>;
type TestPeer = ReturnType<typeof socket>;
const instances: App[] = [];
const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(instances.map(instance => instance.stop()));
  instances.length = 0;
  for (const directory of temporaryDirectories) rmSync(directory, { recursive: true, force: true });
  temporaryDirectories.length = 0;
});

function staticFixture() {
  const root = mkdtempSync(join(tmpdir(), 'pocketdesk-browser-static-'));
  temporaryDirectories.push(root);
  for (const directory of ['BrowserClient/src/viewer', 'BrowserProbe', 'BrowserFixtures']) {
    mkdirSync(join(root, directory), { recursive: true });
  }
  writeFileSync(join(root, 'BrowserClient/index.html'), '<!doctype html><script type="module" src="/app.js"></script>');
  writeFileSync(join(root, 'BrowserClient/app.js'), 'export const app = true;');
  writeFileSync(join(root, 'BrowserClient/style.css'), 'body { color: black; }');
  writeFileSync(join(root, 'BrowserClient/src/viewer/viewer.js'), 'export const viewer = true;');
  writeFileSync(join(root, 'BrowserProbe/index.html'), '<!doctype html><script type="module" src="./probe.js"></script>');
  writeFileSync(join(root, 'BrowserProbe/probe.js'), 'export const probe = true;');
  writeFileSync(join(root, 'BrowserProbe/probe.css'), 'body { color: blue; }');
  writeFileSync(join(root, 'BrowserFixtures/code-scene.js'), 'export const frame = 1;');
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

async function connectHost(app: App) {
  const host = socket(app, '/browser-host');
  await host.open;
  host.send({ type: 'host', hostID, token: hostToken });
  expect(await host.next()).toEqual({ type: 'registered', hostID });
  return host;
}

function installTicket(host: TestPeer, value = ticket, targetSession = session, ttl = 1_000) {
  host.send({ type: 'ticket', ticket: value, session: targetSession, expires: String(Date.now() + ttl), peerID });
}

async function connectBrowser(app: App, value = ticket, targetSession = session) {
  const browser = socket(app, '/browser-signal', `http://127.0.0.1:${app.port}`);
  await browser.open;
  browser.send({ type: 'browser', hostID, session: targetSession, ticket: value });
  return browser;
}

test('static GETs are inert, exact, and carry restrictive headers', async () => {
  const app = setup();
  for (const [path, marker] of [
    ['/', '<!doctype html>'], ['/app.js', 'app = true'], ['/style.css', 'color: black'],
    ['/src/viewer/viewer.js', 'viewer = true'], ['/probe/', '<!doctype html>'],
    ['/probe/probe.js', 'probe = true'], ['/probe/probe.css', 'color: blue'],
    ['/fixtures/code-scene.js', 'frame = 1'],
  ]) {
    const response = await fetch(`http://127.0.0.1:${app.port}${path}`);
    expect(response.status).toBe(200);
    expect(await response.text()).toContain(marker);
    expect(response.headers.get('cache-control')).toBe('no-store');
    expect(response.headers.get('referrer-policy')).toBe('no-referrer');
    expect(response.headers.get('content-security-policy')).toContain("script-src 'self'");
    expect(response.headers.get('content-security-policy')).not.toContain("'unsafe-inline'");
  }
  expect((await fetch(`http://127.0.0.1:${app.port}/browser-api/${hostID}/challenge`)).status).toBe(404);
  expect((await fetch(`http://127.0.0.1:${app.port}/signal`)).status).toBe(404);
  expect((await fetch(`http://127.0.0.1:${app.port}/probe`)).status).toBe(404);
});

test('static traversal and symlink escape cannot expose content', async () => {
  const root = staticFixture();
  const outside = join(root, '..', `pocketdesk-secret-${Date.now()}.js`);
  writeFileSync(outside, 'secret');
  temporaryDirectories.push(outside);
  symlinkSync(outside, join(root, 'BrowserClient/src/leak.js'));
  const app = createBrowserService({ staticRoot: root }); instances.push(app);
  expect((await fetch(`http://127.0.0.1:${app.port}/src/leak.js`)).status).toBe(404);
  expect((await fetch(`http://127.0.0.1:${app.port}/src/%2e%2e%2fapp.js`)).status).toBe(404);
  expect((await fetch(`http://127.0.0.1:${app.port}/src/.hidden`)).status).toBe(404);

  const linkedRoot = mkdtempSync(join(tmpdir(), 'pocketdesk-browser-linked-root-'));
  const outsideRoot = mkdtempSync(join(tmpdir(), 'pocketdesk-browser-outside-root-'));
  temporaryDirectories.push(linkedRoot, outsideRoot);
  writeFileSync(join(outsideRoot, 'index.html'), 'outside root secret');
  symlinkSync(outsideRoot, join(linkedRoot, 'BrowserClient'), 'dir');
  const linked = createBrowserService({ staticRoot: linkedRoot }); instances.push(linked);
  expect((await fetch(`http://127.0.0.1:${linked.port}/`)).status).toBe(404);
});

test('Host and Origin are exact and browser mode/body shapes fail closed', async () => {
  const app = setup();
  const base = `http://127.0.0.1:${app.port}`;
  expect((await fetch(`${base}/`, { headers: { Host: 'evil.example' } })).status).toBe(421);
  expect((await fetch(`${base}/browser-signal`, { headers: { Origin: 'https://evil.example' } })).status).toBe(403);
  expect((await fetch(`${base}/browser-host`, { headers: { Origin: base } })).status).toBe(403);

  await connectHost(app);
  const endpoint = `${base}/browser-api/${hostID}/challenge`;
  const invalidOrigin = await fetch(endpoint, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: 'https://evil.example' },
    body: JSON.stringify({ peerID, nonce, mode: 'view' }),
  });
  expect(invalidOrigin.status).toBe(403);
  for (const body of [
    { peerID, nonce, mode: 'control' },
    { peerID, nonce, mode: 'view', extra: true },
    { peerID: peerID.toUpperCase(), nonce, mode: 'view' },
  ]) {
    const response = await fetch(endpoint, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Origin: base }, body: JSON.stringify(body),
    });
    expect(response.status).toBe(400);
  }

  const enrollEndpoint = `${base}/browser-api/${hostID}/enroll`;
  for (const body of [
    { secret: nonce, peerID, publicKey },
    { nonce: enrollmentNonce, payload: Buffer.alloc(15).toString('base64') },
    { nonce: enrollmentNonce, payload: Buffer.alloc(1025).toString('base64') },
    { nonce: enrollmentNonce, payload: Buffer.alloc(16, 255).toString('base64').replaceAll('/', '_') },
    { nonce: enrollmentNonce, payload: Buffer.alloc(16).toString('base64').replace(/=+$/, '') },
    { nonce: nonce, payload: enrollmentPayload },
    { nonce: enrollmentNonce, payload: enrollmentPayload, peerID },
  ]) {
    const response = await fetch(enrollEndpoint, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Origin: base }, body: JSON.stringify(body),
    });
    expect(response.status).toBe(400);
  }
});

test('host registration is self-authenticating and first message times out', async () => {
  const app = setup({ authTimeoutMs: 20 });
  const idle = socket(app, '/browser-host'); await idle.open;
  expect(await idle.next()).toEqual({ type: 'error', code: 'authentication_timeout' });

  const idleBrowser = socket(app, '/browser-signal', `http://127.0.0.1:${app.port}`); await idleBrowser.open;
  expect(await idleBrowser.next()).toEqual({ type: 'error', code: 'authentication_timeout' });

  const wrong = socket(app, '/browser-host'); await wrong.open;
  wrong.send({ type: 'host', hostID, token: 'f'.repeat(64) });
  expect(await wrong.next()).toEqual({ type: 'error', code: 'unauthorized' });
});

test('HTTP operations are strictly shaped and forwarded only to their authenticated host', async () => {
  const app = setup(), host = await connectHost(app);
  const origin = `http://127.0.0.1:${app.port}`;
  const request = fetch(`${origin}/browser-api/${hostID}/challenge`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin },
    body: JSON.stringify({ peerID, nonce, mode: 'interactive' }),
  });
  const rpc = await host.next();
  expect(rpc.type).toBe('request');
  expect(rpc.operation).toBe('challenge');
  expect(rpc.body).toEqual({ peerID, nonce, mode: 'interactive' });
  expect(rpc.id).toMatch(HEX_32_FOR_TEST);
  host.send({ type: 'response', id: rpc.id, body: { fields: ['safe'], signature } });
  const response = await request;
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({ fields: ['safe'], signature });

  const badProof = await fetch(`${origin}/browser-api/${hostID}/proof`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin },
    body: JSON.stringify({ session, publicKey, signature: 'not-base64' }),
  });
  expect(badProof.status).toBe(400);
  const unavailable = await fetch(`${origin}/browser-api/${'f'.repeat(64)}/enroll`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin },
    body: JSON.stringify({ nonce: enrollmentNonce, payload: enrollmentPayload }),
  });
  expect(unavailable.status).toBe(503);
});

test('enrollment approval has a separate deadline, cancels on expiry, and ignores a late response', async () => {
  const app = setup({ enrollmentTimeoutMs: 30 }), host = await connectHost(app);
  const origin = `http://127.0.0.1:${app.port}`;
  const enrollment = fetch(`${origin}/browser-api/${hostID}/enroll`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin },
    body: JSON.stringify({ nonce: enrollmentNonce, payload: enrollmentPayload }),
  });
  const enrollmentRPC = await host.next();
  expect(enrollmentRPC.operation).toBe('enroll');
  expect(enrollmentRPC.body).toEqual({ nonce: enrollmentNonce, payload: enrollmentPayload });
  expect((await enrollment).status).toBe(504);
  expect(await host.next()).toEqual({ type: 'cancel', id: enrollmentRPC.id });

  host.send({ type: 'response', id: enrollmentRPC.id, body: { receipt: 'late', signature } });
  const challenge = fetch(`${origin}/browser-api/${hostID}/challenge`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin },
    body: JSON.stringify({ peerID, nonce, mode: 'view' }),
  });
  const challengeRPC = await host.next();
  expect(challengeRPC.operation).toBe('challenge');
  host.send({ type: 'response', id: challengeRPC.id, body: { fields: ['alive'], signature } });
  expect((await challenge).status).toBe(200);
  expect(host.ws.readyState).toBe(WebSocket.OPEN);
});

test('HTTP abort cancels its matching host RPC', async () => {
  const app = setup(), host = await connectHost(app);
  const origin = `http://127.0.0.1:${app.port}`;
  const controller = new AbortController();
  const pending = fetch(`${origin}/browser-api/${hostID}/challenge`, {
    method: 'POST', signal: controller.signal,
    headers: { 'Content-Type': 'application/json', Origin: origin },
    body: JSON.stringify({ peerID, nonce, mode: 'view' }),
  });
  const rpc = await host.next();
  controller.abort();
  await expect(pending).rejects.toThrow();
  expect(await host.next()).toEqual({ type: 'cancel', id: rpc.id });
});

test('a host cannot answer another host connection request', async () => {
  const app = setup(), host = await connectHost(app);
  const otherToken = '1'.repeat(64);
  const otherHostID = createHash('sha256').update(otherToken).digest('hex');
  const other = socket(app, '/browser-host');
  await other.open;
  other.send({ type: 'host', hostID: otherHostID, token: otherToken });
  expect(await other.next()).toEqual({ type: 'registered', hostID: otherHostID });

  const origin = `http://127.0.0.1:${app.port}`;
  const pending = fetch(`${origin}/browser-api/${hostID}/challenge`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin },
    body: JSON.stringify({ peerID, nonce, mode: 'view' }),
  });
  const rpc = await host.next();
  other.send({ type: 'response', id: rpc.id, body: { fields: ['spoofed'], signature } });
  expect(await other.next()).toEqual({ type: 'error', code: 'invalid_message' });
  host.send({ type: 'response', id: rpc.id, body: { fields: ['host'], signature } });
  expect(await (await pending).json()).toEqual({ fields: ['host'], signature });
});

const HEX_32_FOR_TEST = /^[a-f0-9]{64}$/;

test('ticket admits one browser and relays only that session', async () => {
  const app = setup(), host = await connectHost(app);
  installTicket(host);
  const browser = await connectBrowser(app);
  expect(await host.next()).toEqual({ type: 'ice', session, servers: [], policy: 'all' });
  expect(await host.next()).toEqual({ type: 'joined', session });
  expect(await browser.next()).toEqual({ type: 'registered', session });
  expect(await browser.next()).toEqual({ type: 'ice', servers: [], policy: 'all' });
  installTicket(host, '1'.repeat(64), '2'.repeat(64));
  expect(await host.next()).toEqual({ type: 'error', code: 'busy' });

  const browserEnvelope = { sequence: '1', direction: 'browser', payload: 'opaque' };
  browser.send({ type: 'signal', session, envelope: browserEnvelope });
  expect(await host.next()).toEqual({ type: 'signal', session, envelope: browserEnvelope });
  const hostEnvelope = { sequence: '1', direction: 'host', payload: 'opaque-response' };
  host.send({ type: 'signal', session, envelope: hostEnvelope });
  expect(await browser.next()).toEqual({ type: 'signal', session, envelope: hostEnvelope });
});

test('peer count and message rate limits have bounded failures', async () => {
  const peerApp = setup({ maxPeers: 1, authTimeoutMs: 500 });
  const openPeer = socket(peerApp, '/browser-host'); await openPeer.open;
  expect((await fetch(`http://127.0.0.1:${peerApp.port}/browser-host`)).status).toBe(503);
  openPeer.ws.close();

  const rateApp = setup({ messagesPerSecond: 1 });
  const host = await connectHost(rateApp);
  host.send({ type: 'stop' });
  expect(await host.next()).toEqual({ type: 'error', code: 'rate_limit' });
});

test('known ticket is atomically consumed even by a wrong-session redemption', async () => {
  const app = setup(), host = await connectHost(app);
  installTicket(host);
  const wrong = await connectBrowser(app, ticket, '1'.repeat(64));
  expect(await wrong.next()).toEqual({ type: 'error', code: 'unauthorized' });
  const replay = await connectBrowser(app);
  expect(await replay.next()).toEqual({ type: 'error', code: 'unauthorized' });
});

test('simultaneous redemption has one winner and ticket replay loses', async () => {
  const app = setup(), host = await connectHost(app);
  installTicket(host);
  const first = socket(app, '/browser-signal', `http://127.0.0.1:${app.port}`);
  const second = socket(app, '/browser-signal', `http://127.0.0.1:${app.port}`);
  await Promise.all([first.open, second.open]);
  first.send({ type: 'browser', hostID, session, ticket });
  second.send({ type: 'browser', hostID, session, ticket });
  const [a, b] = await Promise.all([first.next(), second.next()]);
  expect([a.type, b.type].sort()).toEqual(['error', 'registered']);
  expect([a, b].find(value => value.type === 'error')?.code).toBe('unauthorized');
  expect(await host.next()).toEqual({ type: 'ice', session, servers: [], policy: 'all' });
  expect(await host.next()).toEqual({ type: 'joined', session });
});

test('ticket lifetime is capped, expiration fails closed, and one pending ticket is enforced', async () => {
  const app = setup({ ticketTTLms: 40 }), host = await connectHost(app);
  installTicket(host, ticket, session, 20);
  await Bun.sleep(35);
  const expired = await connectBrowser(app);
  expect(await expired.next()).toEqual({ type: 'error', code: 'unauthorized' });

  installTicket(host, '1'.repeat(64), '2'.repeat(64), 20);
  installTicket(host, '3'.repeat(64), '4'.repeat(64), 20);
  expect(await host.next()).toEqual({ type: 'error', code: 'busy' });
  installTicket(host, '5'.repeat(64), '6'.repeat(64), 1_000);
  expect(await host.next()).toEqual({ type: 'error', code: 'invalid_ticket' });
});

test('host Stop invalidates tickets and active sessions without touching native routes', async () => {
  const app = setup(), host = await connectHost(app);
  installTicket(host);
  host.send({ type: 'stop' });
  const denied = await connectBrowser(app);
  expect(await denied.next()).toEqual({ type: 'error', code: 'unauthorized' });
  expect((await fetch(`http://127.0.0.1:${app.port}/signal`)).status).toBe(404);

  installTicket(host, '1'.repeat(64), '2'.repeat(64));
  const browser = await connectBrowser(app, '1'.repeat(64), '2'.repeat(64));
  expect(await host.next()).toEqual({ type: 'ice', session: '2'.repeat(64), servers: [], policy: 'all' });
  expect(await host.next()).toEqual({ type: 'joined', session: '2'.repeat(64) });
  expect(await browser.next()).toEqual({ type: 'registered', session: '2'.repeat(64) });
  expect(await browser.next()).toEqual({ type: 'ice', servers: [], policy: 'all' });
  const closed = new Promise<CloseEvent>(resolve => { browser.ws.onclose = resolve; });
  host.send({ type: 'stop' });
  expect((await closed).code).toBe(1000);
});

test('host disconnect cancels RPC, invalidates authority, and closes its browser', async () => {
  const app = setup(), host = await connectHost(app);
  const origin = `http://127.0.0.1:${app.port}`;
  const pending = fetch(`${origin}/browser-api/${hostID}/challenge`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin },
    body: JSON.stringify({ peerID, nonce, mode: 'view' }),
  });
  await host.next();
  host.ws.close();
  expect((await pending).status).toBe(503);

  const replacement = await connectHost(app);
  installTicket(replacement);
  const browser = await connectBrowser(app);
  await replacement.next(); await replacement.next(); await browser.next(); await browser.next();
  const closed = new Promise<CloseEvent>(resolve => { browser.ws.onclose = resolve; });
  replacement.ws.close();
  expect((await closed).code).toBe(1000);
});

test('service stop clears all sockets and is idempotent', async () => {
  const app = setup(), host = await connectHost(app);
  installTicket(host);
  const browser = await connectBrowser(app);
  await host.next(); await host.next(); await browser.next(); await browser.next();
  const hostClosed = new Promise<CloseEvent>(resolve => { host.ws.onclose = resolve; });
  const browserClosed = new Promise<CloseEvent>(resolve => { browser.ws.onclose = resolve; });
  await app.stop();
  const [hostEvent, browserEvent] = await Promise.all([hostClosed, browserClosed]);
  expect([1000, 1001]).toContain(hostEvent.code);
  expect([1000, 1001]).toContain(browserEvent.code);
  await app.stop();
});
