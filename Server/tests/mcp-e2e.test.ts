import { afterEach, beforeEach, expect, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { createMcpApp, type McpApp } from '../src/mcp/app';
import { createFakeBridge, FakeClock, pkcePair } from './mcp-fixtures';

const ORIGIN = 'https://mcp.pocketdesk.test';
const HOST_ID = 'b'.repeat(64);

let privateDir: string;
let clock: FakeClock;
let bridgeCtl: ReturnType<typeof createFakeBridge>;
let app: McpApp;

beforeEach(() => {
  privateDir = mkdtempSync(join(tmpdir(), 'pocketdesk-mcp-e2e-'));
  clock = new FakeClock();
  bridgeCtl = createFakeBridge({ hostID: HOST_ID });
  app = createMcpApp({ origin: ORIGIN, privateDir, now: clock.now, host: bridgeCtl.bridge });
});

afterEach(async () => {
  await app.stop();
  rmSync(privateDir, { recursive: true, force: true });
});

async function obtainAccessToken(): Promise<string> {
  const redirectUri = 'https://client.test/callback';
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
  authorizeUrl.searchParams.set('scope', 'desktop.access');
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
  return tokens.access_token as string;
}

test('an SDK client over the Web-Standard transport can list tools and call one with a valid token', async () => {
  const accessToken = await obtainAccessToken();
  const fetchImpl = ((input: RequestInfo | URL, init?: RequestInit) => app.handle(new Request(input as any, init))) as typeof fetch;
  const transport = new StreamableHTTPClientTransport(new URL(`${ORIGIN}/mcp`), {
    fetch: fetchImpl,
    requestInit: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
  const client = new Client({ name: 'test-client', version: '1.0.0' });
  await client.connect(transport);

  const tools = await client.listTools();
  const names = tools.tools.map(tool => tool.name).sort();
  expect(names).toEqual(['inspect_screen', 'request_desktop_access', 'session_status', 'stop_session']);

  const result = await client.callTool({ name: 'request_desktop_access', arguments: {} });
  expect(result.isError).toBeFalsy();
  const structured = (result as any).structuredContent;
  expect(typeof structured.viewerURL).toBe('string');
  expect(structured.viewerURL.startsWith(`${ORIGIN}/?intent=`)).toBe(true);
  expect(structured.readiness).toBe('ready');

  await client.close();
});
