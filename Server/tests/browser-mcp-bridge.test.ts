import { afterEach, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  createBrowserMcpHostBridge,
  type BrowserMcpHostBridge,
  type HostRpcReply,
} from '../src/browser/mcp-host-bridge';
import { createBrowserService, type BrowserServiceConfig } from '../src/browser/service';

const hostToken = 'a'.repeat(64);
const hostID = createHash('sha256').update(hostToken).digest('hex');
const otherHostID = 'b'.repeat(64);
const sessionID = 'c'.repeat(64);

type RequestRecord = {
  hostID: string;
  operation: string;
  body: Record<string, unknown>;
};

function bridgeFixture() {
  let now = 1_700_000_000_000;
  let authorizationHostID: string | undefined = hostID;
  let reply: HostRpcReply = { kind: 'response', body: { approved: true, hostID } };
  const requests: RequestRecord[] = [];
  const sessions = new Map<string, { hostID: string; scope: 'view' | 'control' }>();
  const stopped: string[] = [];
  const bridge = createBrowserMcpHostBridge({
    now: () => now,
    authorizationHostID: () => authorizationHostID,
    hostConnected: candidate => candidate === hostID || candidate === otherHostID,
    async request(hostID, operation, body) {
      requests.push({ hostID, operation, body });
      return reply;
    },
    session(host, session) {
      const record = sessions.get(session);
      return record?.hostID === host ? { scope: record.scope } : undefined;
    },
    stopSession(host, session) {
      const record = sessions.get(session);
      if (!record || record.hostID !== host) return false;
      sessions.delete(session);
      stopped.push(`${host}:${session}`);
      return true;
    },
  });
  return {
    bridge,
    requests,
    sessions,
    stopped,
    advance(ms: number) { now += ms; },
    setAuthorizationHost(value: string | undefined) { authorizationHostID = value; },
    setReply(value: HostRpcReply) { reply = value; },
  };
}

test('authorization uses the authenticated host request channel and approves only an exact matching reply', async () => {
  const fixture = bridgeFixture();
  const signal = new AbortController().signal;
  expect(await fixture.bridge.requestAuthorization({ clientName: 'Claude', redirectHost: 'claude.ai', code: 'ABC123', signal }))
    .toEqual({ decision: 'approved', hostID });
  expect(fixture.requests).toEqual([{ hostID, operation: 'mcp_authorize', body: {
    clientName: 'Claude', redirectHost: 'claude.ai', code: 'ABC123',
  } }]);

  for (const malformed of [
    { approved: true },
    { approved: true, hostID: otherHostID },
    { approved: true, hostID, extra: true },
    { approved: false, hostID },
    { approved: 'yes', hostID },
  ]) {
    fixture.setReply({ kind: 'response', body: malformed });
    expect((await fixture.bridge.requestAuthorization({ clientName: 'Claude', redirectHost: 'claude.ai', code: 'ABC123', signal })).decision)
      .toBe('denied');
  }
});

test('offline, denied, aborted, and malformed authorization fail closed', async () => {
  const fixture = bridgeFixture();
  const signal = new AbortController().signal;
  fixture.setAuthorizationHost(undefined);
  expect((await fixture.bridge.requestAuthorization({ clientName: 'ChatGPT', redirectHost: 'chatgpt.com', code: '123456', signal })).decision)
    .toBe('offline');

  fixture.setAuthorizationHost(hostID);
  fixture.setReply({ kind: 'response', body: { approved: false } });
  expect((await fixture.bridge.requestAuthorization({ clientName: 'ChatGPT', redirectHost: 'chatgpt.com', code: '123456', signal })).decision)
    .toBe('denied');
  fixture.setReply({ kind: 'aborted' });
  expect((await fixture.bridge.requestAuthorization({ clientName: 'ChatGPT', redirectHost: 'chatgpt.com', code: '123456', signal })).decision)
    .toBe('timeout');
  fixture.setReply({ kind: 'error', code: 'unsupported_operation' });
  expect((await fixture.bridge.requestAuthorization({ clientName: 'ChatGPT', redirectHost: 'chatgpt.com', code: '123456', signal })).decision)
    .toBe('denied');
});

test('host status accepts only the exact readiness response', async () => {
  const fixture = bridgeFixture();
  fixture.setReply({ kind: 'response', body: { readiness: 'permissions_missing' } });
  expect(await fixture.bridge.hostStatus(hostID)).toBe('permissions_missing');
  expect(fixture.requests.at(-1)).toEqual({ hostID, operation: 'mcp_status', body: {} });
  fixture.setReply({ kind: 'response', body: { readiness: 'ready', extra: true } });
  expect(await fixture.bridge.hostStatus(hostID)).toBe('host_offline');
  fixture.setReply({ kind: 'response', body: { readiness: 'invented' } });
  expect(await fixture.bridge.hostStatus(hostID)).toBe('host_offline');
});

test('intents are grant-owned, expire, and associate only to their own host session', async () => {
  const fixture = bridgeFixture();
  const first = await fixture.bridge.createIntent({ hostID, grantId: 'grant-a', ttlMs: 1_000 });
  const other = await fixture.bridge.createIntent({ hostID: otherHostID, grantId: 'grant-b', ttlMs: 1_000 });
  expect(first.intentID).toMatch(/^[a-f0-9]{64}$/);
  expect(first.intentID).not.toBe(other.intentID);

  fixture.sessions.set(sessionID, { hostID, scope: 'control' });
  expect(fixture.bridge.associateSession({ intentID: first.intentID, hostID: otherHostID, sessionID, scope: 'control' })).toBe(false);
  expect(fixture.bridge.associateSession({ intentID: first.intentID, hostID, sessionID, scope: 'control' })).toBe(true);
  expect(await fixture.bridge.sessionForIntent(first.intentID)).toMatchObject({ connection: 'connected', sessionID, scope: 'control' });
  expect(await fixture.bridge.sessionForIntent(other.intentID)).toMatchObject({ connection: 'none' });

  fixture.advance(1_001);
  expect(await fixture.bridge.lookupIntent(first.intentID)).toBeUndefined();
  expect(await fixture.bridge.sessionForIntent(first.intentID)).toBeUndefined();
});

test('stop can end only the exactly associated host session', async () => {
  const fixture = bridgeFixture();
  const intent = await fixture.bridge.createIntent({ hostID, grantId: 'grant-a', ttlMs: 1_000 });
  fixture.sessions.set(sessionID, { hostID, scope: 'view' });
  expect(fixture.bridge.associateSession({ intentID: intent.intentID, hostID, sessionID, scope: 'view' })).toBe(true);

  expect(await fixture.bridge.stopSession(otherHostID, sessionID)).toBe('already_ended');
  expect(fixture.stopped).toEqual([]);
  expect(await fixture.bridge.stopSession(hostID, 'd'.repeat(64))).toBe('already_ended');
  expect(fixture.stopped).toEqual([]);
  expect(await fixture.bridge.stopSession(hostID, sessionID)).toBe('stopped');
  expect(fixture.stopped).toEqual([`${hostID}:${sessionID}`]);
  expect(await fixture.bridge.stopSession(hostID, sessionID)).toBe('already_ended');
});

test('inspection and revocation remain explicitly unavailable until the Mac implements them', async () => {
  const fixture = bridgeFixture();
  expect(await fixture.bridge.inspectionGrant(hostID)).toBeNull();
  await expect(fixture.bridge.captureInspectionFrame(hostID, new AbortController().signal)).rejects.toThrow('inspection_unavailable');
  const listener = () => { throw new Error('must not be called'); };
  const unsubscribe = fixture.bridge.onGrantRevoked(listener);
  unsubscribe();
  const intent = await fixture.bridge.createIntent({ hostID, grantId: 'grant-a', ttlMs: 1_000 });
  fixture.bridge.stop();
  fixture.bridge.stop();
  expect(await fixture.bridge.lookupIntent(intent.intentID)).toBeUndefined();
  expect(await fixture.bridge.hostStatus(hostID)).toBe('host_offline');
});

type App = ReturnType<typeof createBrowserService>;
const apps: App[] = [];
const dirs: string[] = [];

afterEach(async () => {
  await Promise.all(apps.map(app => app.stop()));
  apps.length = 0;
  dirs.splice(0).forEach(dir => rmSync(dir, { recursive: true, force: true }));
});

function service(config: BrowserServiceConfig = {}) {
  const app = createBrowserService(config);
  apps.push(app);
  return app;
}

function productionHostSocket(app: App) {
  const ws = new WebSocket(`ws://127.0.0.1:${app.port}/browser-host`, { headers: { Host: 'desk.example' } });
  const messages: any[] = [];
  const waiters: Array<(value: any) => void> = [];
  ws.onmessage = event => {
    const value = JSON.parse(String(event.data));
    const waiter = waiters.shift();
    if (waiter) waiter(value); else messages.push(value);
  };
  const open = new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = reject; });
  const next = () => messages.length ? Promise.resolve(messages.shift()) : new Promise<any>(resolve => waiters.push(resolve));
  return { ws, open, next, send(value: unknown) { ws.send(JSON.stringify(value)); } };
}

async function beginServiceAuthorization(app: App, privateHeaders: Record<string, string>) {
  const local = `http://127.0.0.1:${app.port}`;
  const redirectUri = 'https://client.example/callback';
  const registration = await fetch(`${local}/oauth/register`, {
    method: 'POST',
    headers: { ...privateHeaders, 'Content-Type': 'application/json' },
    body: JSON.stringify({ redirect_uris: [redirectUri] }),
  });
  const { client_id } = await registration.json() as { client_id: string };
  const verifier = 'v'.repeat(48);
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  const authorize = new URL(`${local}/oauth/authorize`);
  authorize.searchParams.set('response_type', 'code');
  authorize.searchParams.set('client_id', client_id);
  authorize.searchParams.set('redirect_uri', redirectUri);
  authorize.searchParams.set('code_challenge', challenge);
  authorize.searchParams.set('code_challenge_method', 'S256');
  authorize.searchParams.set('resource', 'https://desk.example/mcp');
  const page = await fetch(authorize, { headers: privateHeaders });
  const html = await page.text();
  const requestID = /data-request-id="([a-f0-9]+)"/.exec(html)?.[1];
  expect(page.status).toBe(200);
  expect(requestID).toBeTruthy();
  return { local, requestID: requestID! };
}

test('production service sends the exact authorization wire shape and rejects a malformed host approval', async () => {
  const privateDir = mkdtempSync(join(tmpdir(), 'pocketdesk-browser-mcp-'));
  dirs.push(privateDir);
  const app = service({ origin: 'https://desk.example', mcpPrivateDir: privateDir });
  const host = productionHostSocket(app);
  await host.open;
  host.send({ type: 'host', hostID, token: hostToken });
  expect(await host.next()).toEqual({ type: 'registered', hostID });

  const { local, requestID } = await beginServiceAuthorization(app, { Host: 'desk.example' });
  const request = await host.next();
  expect(request).toMatchObject({ type: 'request', operation: 'mcp_authorize' });
  expect(Object.keys(request.body).sort()).toEqual(['clientName', 'code', 'redirectHost']);
  expect(request.body.redirectHost).toBe('client.example');
  expect(request.body.code).toMatch(/^[A-Z0-9]{6}$/);
  host.send({ type: 'response', id: request.id, body: { approved: true, hostID, extra: true } });

  for (let attempt = 0; attempt < 20; attempt++) {
    const poll = await fetch(`${local}/oauth/authorize/poll?request_id=${requestID}`, { headers: { Host: 'desk.example' } });
    const result = await poll.json() as { status: string };
    if (result.status !== 'pending') {
      expect(result.status).toBe('denied');
      host.ws.close();
      return;
    }
    await Bun.sleep(5);
  }
  throw new Error('authorization did not settle');
});

test('MCP routes mount only with an HTTPS origin and private directory, retaining exact Host validation and 401 metadata', async () => {
  const privateDir = mkdtempSync(join(tmpdir(), 'pocketdesk-browser-mcp-'));
  dirs.push(privateDir);
  const app = service({ origin: 'https://desk.example', mcpPrivateDir: privateDir });
  const local = `http://127.0.0.1:${app.port}`;
  const headers = { Host: 'desk.example' };

  const metadata = await fetch(`${local}/.well-known/oauth-protected-resource`, { headers });
  expect(metadata.status).toBe(200);
  expect(await metadata.json()).toMatchObject({ resource: 'https://desk.example/mcp' });
  const unauthorized = await fetch(`${local}/mcp`, { method: 'POST', headers });
  expect(unauthorized.status).toBe(401);
  expect(unauthorized.headers.get('www-authenticate')).toBe(
    'Bearer resource_metadata="https://desk.example/.well-known/oauth-protected-resource"',
  );
  expect((await fetch(`${local}/mcp`, { method: 'POST', headers: { Host: 'evil.example' } })).status).toBe(421);
});

test('MCP routes are absent when unconfigured and a private directory without HTTPS origin is rejected', async () => {
  const unconfigured = service();
  expect((await fetch(`http://127.0.0.1:${unconfigured.port}/mcp`, { method: 'POST' })).status).toBe(404);

  const privateDir = mkdtempSync(join(tmpdir(), 'pocketdesk-browser-mcp-'));
  dirs.push(privateDir);
  expect(() => createBrowserService({ mcpPrivateDir: privateDir })).toThrow('MCP requires an exact HTTPS origin');

  const originOnly = service({ origin: 'https://desk.example' });
  expect((await fetch(`http://127.0.0.1:${originOnly.port}/mcp`, {
    method: 'POST', headers: { Host: 'desk.example' },
  })).status).toBe(404);
});

test('service stop tears down the mounted MCP service and remains idempotent', async () => {
  const privateDir = mkdtempSync(join(tmpdir(), 'pocketdesk-browser-mcp-'));
  dirs.push(privateDir);
  const app = service({ origin: 'https://desk.example', mcpPrivateDir: privateDir });
  const local = `http://127.0.0.1:${app.port}`;
  expect((await fetch(`${local}/.well-known/oauth-protected-resource`, { headers: { Host: 'desk.example' } })).status).toBe(200);
  await app.stop();
  await app.stop();
  await expect(fetch(`${local}/.well-known/oauth-protected-resource`, { headers: { Host: 'desk.example' } })).rejects.toThrow();
});
