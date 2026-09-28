import { afterEach, beforeEach, expect, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createMcpApp, type McpApp } from '../src/mcp/app';
import { createFakeBridge, FakeClock, pkcePair } from './mcp-fixtures';

const ORIGIN = 'https://mcp.pocketdesk.test';
const HOST_ID = 'c'.repeat(64);

let privateDir: string;
let clock: FakeClock;
let bridgeCtl: ReturnType<typeof createFakeBridge>;
let app: McpApp;

beforeEach(() => {
  privateDir = mkdtempSync(join(tmpdir(), 'pocketdesk-mcp-tools-'));
  clock = new FakeClock();
  bridgeCtl = createFakeBridge({ hostID: HOST_ID });
  app = createMcpApp({ origin: ORIGIN, privateDir, now: clock.now, host: bridgeCtl.bridge });
});

afterEach(async () => {
  await app.stop();
  rmSync(privateDir, { recursive: true, force: true });
});

let clientCounter = 0;

async function obtainToken(scope = 'desktop.access screen.inspect offline_access'): Promise<{ accessToken: string }> {
  clientCounter += 1;
  const redirectUri = `https://client${clientCounter}.test/callback`;
  const registerResponse = await app.handle(new Request(`${ORIGIN}/oauth/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ redirect_uris: [redirectUri] }),
  }));
  const { client_id } = (await registerResponse!.json()) as { client_id: string };
  const { verifier, challenge } = pkcePair();
  const authorizeUrl = new URL(`${ORIGIN}/oauth/authorize`);
  authorizeUrl.searchParams.set('response_type', 'code');
  authorizeUrl.searchParams.set('client_id', client_id);
  authorizeUrl.searchParams.set('redirect_uri', redirectUri);
  authorizeUrl.searchParams.set('code_challenge', challenge);
  authorizeUrl.searchParams.set('code_challenge_method', 'S256');
  authorizeUrl.searchParams.set('resource', `${ORIGIN}/mcp`);
  authorizeUrl.searchParams.set('scope', scope);
  const page = await (await app.handle(new Request(authorizeUrl)))!.text();
  const requestId = /data-request-id="([a-f0-9]+)"/.exec(page)![1];
  bridgeCtl.approveNext();
  let redirect: string | undefined;
  for (let i = 0; i < 20 && !redirect; i++) {
    const poll = await (await app.handle(new Request(`${ORIGIN}/oauth/authorize/poll?request_id=${requestId}`)))!.json();
    if (poll.status === 'approved') redirect = poll.redirect;
    else await new Promise(resolve => setTimeout(resolve, 5));
  }
  const code = new URL(redirect!).searchParams.get('code')!;
  const tokenResponse = await app.handle(new Request(`${ORIGIN}/oauth/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: redirectUri, client_id, code_verifier: verifier }),
  }));
  const tokens = await tokenResponse!.json();
  return { accessToken: tokens.access_token as string };
}

async function callTool(accessToken: string, name: string, args: Record<string, unknown> = {}) {
  const response = await app.handle(new Request(`${ORIGIN}/mcp`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      accept: 'application/json, text/event-stream',
      authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }),
  }));
  expect(response!.status).toBe(200);
  const body = await response!.json();
  return body.result as { isError?: boolean; content: Array<{ type: string; text?: string; data?: string }>; structuredContent?: any };
}

test('a token without screen.inspect scope cannot call inspect_screen', async () => {
  const { accessToken } = await obtainToken('desktop.access');
  const result = await callTool(accessToken, 'inspect_screen');
  expect(result.isError).toBe(true);
  expect(result.content[0]?.text).toBe('insufficient_scope');
});

test('a token without desktop.access scope cannot call request_desktop_access', async () => {
  const { accessToken } = await obtainToken('screen.inspect');
  const result = await callTool(accessToken, 'request_desktop_access');
  expect(result.isError).toBe(true);
  expect(result.content[0]?.text).toBe('insufficient_scope');
});

test('request_desktop_access, session_status, and stop_session round-trip for one intent', async () => {
  const { accessToken } = await obtainToken();
  const created = await callTool(accessToken, 'request_desktop_access');
  const intentID = created.structuredContent.intentID as string;
  expect(created.structuredContent.viewerURL).toContain(intentID);

  bridgeCtl.setSession('sess-1', HOST_ID, { readiness: 'ready', connection: 'connected', scope: 'view' });
  const status = await callTool(accessToken, 'session_status', { intentID });
  expect(status.structuredContent.connection).toBe('connected');

  const stop = await callTool(accessToken, 'stop_session', { intentID });
  expect(stop.structuredContent.stopped).toBe(true);

  const stopAgain = await callTool(accessToken, 'stop_session', { intentID });
  expect(stopAgain.structuredContent.alreadyEnded).toBe(true);
});

test('a second grant cannot see or stop the first grant\'s intent (cross-intent isolation)', async () => {
  const first = await obtainToken();
  const second = await obtainToken();
  const created = await callTool(first.accessToken, 'request_desktop_access');
  const intentID = created.structuredContent.intentID as string;

  const status = await callTool(second.accessToken, 'session_status', { intentID });
  expect(status.isError).toBe(true);
  expect(status.content[0]?.text).toBe('intent_not_found');

  const stop = await callTool(second.accessToken, 'stop_session', { intentID });
  expect(stop.isError).toBe(true);
  expect(stop.content[0]?.text).toBe('intent_not_found');
});

test('inspect_screen is denied without an active Mac inspection grant, and denied once it expires', async () => {
  const { accessToken } = await obtainToken();
  const denied = await callTool(accessToken, 'inspect_screen');
  expect(denied.isError).toBe(true);
  expect(denied.content[0]?.text).toBe('inspection_not_granted');

  bridgeCtl.setInspectionGrant(HOST_ID, { active: true, expiresAt: clock.now() + 1_000, display: 'main' });
  clock.advance(2_000);
  const expired = await callTool(accessToken, 'inspect_screen');
  expect(expired.isError).toBe(true);
  expect(expired.content[0]?.text).toBe('inspection_expired');
});

test('inspect_screen returns an image content block plus a single-use frame URL, and never a token', async () => {
  const { accessToken } = await obtainToken();
  bridgeCtl.setInspectionGrant(HOST_ID, { active: true, expiresAt: clock.now() + 60_000, display: 'main' });
  const jpeg = new Uint8Array([1, 2, 3, 4, 5]);
  bridgeCtl.setNextFrame(jpeg, clock.now());

  const result = await callTool(accessToken, 'inspect_screen');
  expect(result.isError).toBeFalsy();
  const image = result.content.find(block => block.type === 'image');
  expect(image?.data).toBe(Buffer.from(jpeg).toString('base64'));
  const frameURL = result.structuredContent.frameURL as string;
  expect(frameURL).toMatch(/\/mcp-ui\/frame\/[a-f0-9]{32}$/);

  const fullText = JSON.stringify(result);
  expect(fullText).not.toContain(accessToken);
  expect(fullText.toLowerCase()).not.toContain('turn:');
  expect(fullText.toLowerCase()).not.toContain('turns:');

  // The frame is single-use and requires the caller's own bearer.
  const framePath = new URL(frameURL).pathname;
  const noAuth = await app.handle(new Request(`${ORIGIN}${framePath}`));
  expect(noAuth!.status).toBe(401);

  const first = await app.handle(new Request(`${ORIGIN}${framePath}`, { headers: { authorization: `Bearer ${accessToken}` } }));
  expect(first!.status).toBe(200);
  expect(new Uint8Array(await first!.arrayBuffer())).toEqual(jpeg);

  const second = await app.handle(new Request(`${ORIGIN}${framePath}`, { headers: { authorization: `Bearer ${accessToken}` } }));
  expect(second!.status).toBe(404);
});

test('a frame cannot be fetched by a different grant\'s bearer token', async () => {
  const owner = await obtainToken();
  const other = await obtainToken();
  bridgeCtl.setInspectionGrant(HOST_ID, { active: true, expiresAt: clock.now() + 60_000, display: 'main' });
  bridgeCtl.setNextFrame(new Uint8Array([9, 9, 9]), clock.now());
  const result = await callTool(owner.accessToken, 'inspect_screen');
  const framePath = new URL(result.structuredContent.frameURL).pathname;

  const wrongGrant = await app.handle(new Request(`${ORIGIN}${framePath}`, { headers: { authorization: `Bearer ${other.accessToken}` } }));
  expect(wrongGrant!.status).toBe(404);
});

test('the ui://pocketdesk/viewer resource is registered with CSP scoped to the service origin', async () => {
  const { accessToken } = await obtainToken();
  const response = await app.handle(new Request(`${ORIGIN}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', authorization: `Bearer ${accessToken}` },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'resources/list', params: {} }),
  }));
  const body = await response!.json();
  const resource = body.result.resources.find((entry: any) => entry.uri === 'ui://pocketdesk/viewer');
  expect(resource).toBeTruthy();
  expect(resource.mimeType).toBe('text/html;profile=mcp-app');
  expect(resource._meta.ui.csp.connectDomains).toEqual([ORIGIN]);
  expect(resource._meta.ui.csp.resourceDomains).toEqual([ORIGIN]);
});
