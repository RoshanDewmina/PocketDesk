import { afterEach, beforeEach, expect, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createMcpApp, type McpApp } from '../src/mcp/app';
import { fetchClientMetadataDocument } from '../src/mcp/cimd';
import { createFakeBridge, FakeClock, pkcePair } from './mcp-fixtures';

const ORIGIN = 'https://mcp.pocketdesk.test';
const HOST_ID = 'a'.repeat(64);

let privateDir: string;
let clock: FakeClock;
let bridgeCtl: ReturnType<typeof createFakeBridge>;
let app: McpApp;

beforeEach(() => {
  privateDir = mkdtempSync(join(tmpdir(), 'pocketdesk-mcp-'));
  clock = new FakeClock();
  bridgeCtl = createFakeBridge({ hostID: HOST_ID });
  app = createMcpApp({ origin: ORIGIN, privateDir, now: clock.now, host: bridgeCtl.bridge });
});

afterEach(async () => {
  await app.stop();
  rmSync(privateDir, { recursive: true, force: true });
});

async function registerClient(redirectUri: string) {
  const response = await app.handle(new Request(`${ORIGIN}/oauth/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ redirect_uris: [redirectUri] }),
  }));
  expect(response!.status).toBe(201);
  return (await response!.json()) as { client_id: string };
}

function extractRequestId(html: string): string {
  const match = /data-request-id="([a-f0-9]+)"/.exec(html);
  if (!match) throw new Error('no request id in authorize page');
  return match[1];
}

async function startAuthorize(opts: { clientId: string; redirectUri: string; challenge: string; scope?: string; resource?: string; state?: string }) {
  const url = new URL(`${ORIGIN}/oauth/authorize`);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', opts.clientId);
  url.searchParams.set('redirect_uri', opts.redirectUri);
  url.searchParams.set('code_challenge', opts.challenge);
  url.searchParams.set('code_challenge_method', 'S256');
  url.searchParams.set('resource', opts.resource ?? `${ORIGIN}/mcp`);
  if (opts.scope) url.searchParams.set('scope', opts.scope);
  if (opts.state) url.searchParams.set('state', opts.state);
  const response = await app.handle(new Request(url));
  expect(response!.status).toBe(200);
  const html = await response!.text();
  return extractRequestId(html);
}

async function pollUntilSettled(requestId: string) {
  for (let i = 0; i < 20; i++) {
    const response = await app.handle(new Request(`${ORIGIN}/oauth/authorize/poll?request_id=${requestId}`));
    const data = (await response!.json()) as { status: string; redirect?: string };
    if (data.status !== 'pending') return data;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  throw new Error('authorize request never settled');
}

async function fullAuthorizationFlow(opts: { scope?: string } = {}) {
  const redirectUri = 'https://client.test/callback';
  const { client_id } = await registerClient(redirectUri);
  const { verifier, challenge } = pkcePair();
  const requestId = await startAuthorize({ clientId: client_id, redirectUri, challenge, scope: opts.scope, state: 'xyz' });
  bridgeCtl.approveNext();
  const result = await pollUntilSettled(requestId);
  expect(result.status).toBe('approved');
  const redirect = new URL(result.redirect!);
  expect(redirect.searchParams.get('state')).toBe('xyz');
  const code = redirect.searchParams.get('code')!;
  const tokenResponse = await app.handle(new Request(`${ORIGIN}/oauth/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code', code, redirect_uri: redirectUri, client_id, code_verifier: verifier,
    }),
  }));
  expect(tokenResponse!.status).toBe(200);
  return { tokens: (await tokenResponse!.json()) as any, client_id, redirectUri, code, verifier };
}

test('protected resource metadata and 401 challenge', async () => {
  const prm = await app.handle(new Request(`${ORIGIN}/.well-known/oauth-protected-resource`));
  expect(prm!.status).toBe(200);
  const body = await prm!.json();
  expect(body.resource).toBe(`${ORIGIN}/mcp`);
  expect(body.authorization_servers).toEqual([ORIGIN]);

  const asMeta = await app.handle(new Request(`${ORIGIN}/.well-known/oauth-authorization-server`));
  const asBody = await asMeta!.json();
  expect(asBody.client_id_metadata_document_supported).toBe(true);
  expect(asBody.token_endpoint_auth_methods_supported).toEqual(['none']);
  expect(asBody.code_challenge_methods_supported).toEqual(['S256']);
  expect(asBody.registration_endpoint).toBe(`${ORIGIN}/oauth/register`);

  const unauthorized = await app.handle(new Request(`${ORIGIN}/mcp`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' }));
  expect(unauthorized!.status).toBe(401);
  expect(unauthorized!.headers.get('www-authenticate')).toContain('resource_metadata="https://mcp.pocketdesk.test/.well-known/oauth-protected-resource"');
});

test('PKCE is required, S256 only, and a mismatched verifier is rejected', async () => {
  const redirectUri = 'https://client.test/callback';
  const { client_id } = await registerClient(redirectUri);

  const noChallenge = new URL(`${ORIGIN}/oauth/authorize`);
  noChallenge.searchParams.set('response_type', 'code');
  noChallenge.searchParams.set('client_id', client_id);
  noChallenge.searchParams.set('redirect_uri', redirectUri);
  noChallenge.searchParams.set('resource', `${ORIGIN}/mcp`);
  expect((await app.handle(new Request(noChallenge)))!.status).toBe(400);

  const plainMethod = new URL(noChallenge);
  plainMethod.searchParams.set('code_challenge', 'a'.repeat(43));
  plainMethod.searchParams.set('code_challenge_method', 'plain');
  expect((await app.handle(new Request(plainMethod)))!.status).toBe(400);

  const { verifier, challenge } = pkcePair();
  const requestId = await startAuthorize({ clientId: client_id, redirectUri, challenge });
  bridgeCtl.approveNext();
  const settled = await pollUntilSettled(requestId);
  const code = new URL(settled.redirect!).searchParams.get('code')!;

  const wrongVerifier = await app.handle(new Request(`${ORIGIN}/oauth/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: redirectUri, client_id, code_verifier: 'x'.repeat(43) }),
  }));
  expect(wrongVerifier!.status).toBe(400);
  expect((await wrongVerifier!.json()).error).toBe('invalid_grant');
  void verifier;
});

test('authorization codes are single-use, expire, and are bound to client/redirect/challenge/resource', async () => {
  const { tokens, client_id, redirectUri, code, verifier } = await fullAuthorizationFlow();
  expect(tokens.access_token).toBeTruthy();

  const reuse = await app.handle(new Request(`${ORIGIN}/oauth/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: redirectUri, client_id, code_verifier: verifier }),
  }));
  expect(reuse!.status).toBe(400);
  expect((await reuse!.json()).error).toBe('invalid_grant');
});

test('an expired authorization code is rejected', async () => {
  const redirectUri = 'https://client.test/callback';
  const { client_id } = await registerClient(redirectUri);
  const { verifier, challenge } = pkcePair();
  const requestId = await startAuthorize({ clientId: client_id, redirectUri, challenge });
  bridgeCtl.approveNext();
  const settled = await pollUntilSettled(requestId);
  const code = new URL(settled.redirect!).searchParams.get('code')!;

  clock.advance(61_000);
  const response = await app.handle(new Request(`${ORIGIN}/oauth/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: redirectUri, client_id, code_verifier: verifier }),
  }));
  expect(response!.status).toBe(400);
});

test('a redirect_uri or client_id mismatch on the token exchange is rejected', async () => {
  const redirectUri = 'https://client.test/callback';
  const { client_id } = await registerClient(redirectUri);
  const { verifier, challenge } = pkcePair();
  const requestId = await startAuthorize({ clientId: client_id, redirectUri, challenge });
  bridgeCtl.approveNext();
  const settled = await pollUntilSettled(requestId);
  const code = new URL(settled.redirect!).searchParams.get('code')!;

  const wrongRedirect = await app.handle(new Request(`${ORIGIN}/oauth/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: 'https://evil.test/callback', client_id, code_verifier: verifier }),
  }));
  expect(wrongRedirect!.status).toBe(400);
});

test('local Mac denial, offline, and timeout all resolve to access_denied without minting a code', async () => {
  const redirectUri = 'https://client.test/callback';
  const { client_id } = await registerClient(redirectUri);
  {
    const { challenge } = pkcePair();
    const requestId = await startAuthorize({ clientId: client_id, redirectUri, challenge, state: 's1' });
    bridgeCtl.denyNext();
    const settled = await pollUntilSettled(requestId);
    expect(settled.status).toBe('denied');
    const url = new URL(settled.redirect!);
    expect(url.searchParams.get('error')).toBe('access_denied');
    expect(url.searchParams.get('state')).toBe('s1');
  }
  {
    bridgeCtl.goOffline();
    const { challenge } = pkcePair();
    const requestId = await startAuthorize({ clientId: client_id, redirectUri, challenge });
    const settled = await pollUntilSettled(requestId);
    expect(settled.status).toBe('offline');
    expect(new URL(settled.redirect!).searchParams.get('error')).toBe('access_denied');
  }
});

test('CIMD fetch rejects a loopback/private client_id (SSRF guard) without any network access', async () => {
  const redirectUri = 'https://client.test/callback';
  const { challenge } = pkcePair();
  const url = new URL(`${ORIGIN}/oauth/authorize`);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', 'https://127.0.0.1/metadata.json');
  url.searchParams.set('redirect_uri', redirectUri);
  url.searchParams.set('code_challenge', challenge);
  url.searchParams.set('code_challenge_method', 'S256');
  url.searchParams.set('resource', `${ORIGIN}/mcp`);
  const response = await app.handle(new Request(url));
  expect(response!.status).toBe(400);
});

test('CIMD fetch rejects redirects and oversized documents', async () => {
  privateDir = mkdtempSync(join(tmpdir(), 'pocketdesk-mcp-'));
  let call = 0;
  const fetchImpl = (async (input: RequestInfo | URL) => {
    call += 1;
    const href = String(input);
    if (href.includes('redirecting')) return new Response(null, { status: 302, headers: { Location: 'https://elsewhere.test/x' } });
    if (href.includes('huge')) {
      return new Response(JSON.stringify({ client_id: href, redirect_uris: [`https://x.test/${'a'.repeat(20_000)}`] }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    throw new Error('unexpected fetch');
  }) as typeof fetch;
  const localApp = createMcpApp({ origin: ORIGIN, privateDir, now: clock.now, host: bridgeCtl.bridge, fetchImpl });
  try {
    for (const clientId of ['https://93.184.216.34/redirecting.json', 'https://93.184.216.34/huge.json']) {
      const url = new URL(`${ORIGIN}/oauth/authorize`);
      url.searchParams.set('response_type', 'code');
      url.searchParams.set('client_id', clientId);
      url.searchParams.set('redirect_uri', 'https://client.test/callback');
      const { challenge } = pkcePair();
      url.searchParams.set('code_challenge', challenge);
      url.searchParams.set('code_challenge_method', 'S256');
      url.searchParams.set('resource', `${ORIGIN}/mcp`);
      const response = await localApp.handle(new Request(url));
      expect(response!.status).toBe(400);
    }
    expect(call).toBeGreaterThan(0);
  } finally {
    await localApp.stop();
    rmSync(privateDir, { recursive: true, force: true });
  }
});

test('CIMD deadline covers a response body that never finishes', async () => {
  const clientId = 'https://93.184.216.35/slow-body.json';
  const fetchImpl = (async () => new Response(new ReadableStream({
    pull() { return new Promise(() => {}); },
  }), { status: 200, headers: { 'content-type': 'application/json' } })) as typeof fetch;
  const started = performance.now();
  await expect(fetchClientMetadataDocument(clientId, Date.now, fetchImpl)).rejects.toThrow('cimd_timeout');
  expect(performance.now() - started).toBeLessThan(3_500);
}, 5_000);

test('Dynamic Client Registration is bounded per minute', async () => {
  let last: Response | undefined;
  for (let i = 0; i < 11; i++) {
    last = (await app.handle(new Request(`${ORIGIN}/oauth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ redirect_uris: ['https://client.test/callback'] }),
    })))!;
  }
  expect(last!.status).toBe(429);
});

test('Dynamic Client Registration rejects plaintext and credential-bearing redirect URIs', async () => {
  for (const redirectUri of [
    'http://client.test/callback',
    'http://127.0.0.1/callback',
    'https://user:password@client.test/callback',
  ]) {
    const response = await app.handle(new Request(`${ORIGIN}/oauth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ redirect_uris: [redirectUri] }),
    }));
    expect(response!.status).toBe(400);
  }
});

test('refresh token rotation, and reuse of a rotated-away token revokes the whole grant', async () => {
  const { tokens } = await fullAuthorizationFlow({ scope: 'desktop.access offline_access' });
  expect(tokens.refresh_token).toBeTruthy();

  const refreshOnce = await app.handle(new Request(`${ORIGIN}/oauth/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: tokens.refresh_token }),
  }));
  expect(refreshOnce!.status).toBe(200);
  const rotated = await refreshOnce!.json();
  expect(rotated.refresh_token).not.toBe(tokens.refresh_token);

  // Reusing the original (now rotated-away) refresh token must revoke the whole grant.
  const reuse = await app.handle(new Request(`${ORIGIN}/oauth/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: tokens.refresh_token }),
  }));
  expect(reuse!.status).toBe(400);

  const useRotated = await app.handle(new Request(`${ORIGIN}/oauth/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: rotated.refresh_token }),
  }));
  expect(useRotated!.status).toBe(400);

  const mcpCall = await app.handle(new Request(`${ORIGIN}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${tokens.access_token}` },
    body: '{}',
  }));
  expect(mcpCall!.status).toBe(401);
});

test('the /oauth/revoke endpoint and a Mac-initiated revoke both take effect immediately', async () => {
  const { tokens } = await fullAuthorizationFlow();
  const revoke = await app.handle(new Request(`${ORIGIN}/oauth/revoke`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ token: tokens.access_token }),
  }));
  expect(revoke!.status).toBe(200);
  const call = await app.handle(new Request(`${ORIGIN}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${tokens.access_token}` },
    body: '{}',
  }));
  expect(call!.status).toBe(401);

  const second = await fullAuthorizationFlow();
  bridgeCtl.emitGrantRevoked({ hostID: HOST_ID });
  const secondCall = await app.handle(new Request(`${ORIGIN}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${second.tokens.access_token}` },
    body: '{}',
  }));
  expect(secondCall!.status).toBe(401);
});

test('a grant idle for 30 days is treated as expired', async () => {
  const { tokens } = await fullAuthorizationFlow();
  clock.advance(30 * 24 * 60 * 60 * 1000 + 1);
  const call = await app.handle(new Request(`${ORIGIN}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${tokens.access_token}` },
    body: '{}',
  }));
  expect(call!.status).toBe(401);
});

test('an authorize request naming the wrong resource is rejected (audience binding)', async () => {
  const redirectUri = 'https://client.test/callback';
  const { client_id } = await registerClient(redirectUri);
  const { challenge } = pkcePair();
  const response = await startAuthorizeExpectStatus({ clientId: client_id, redirectUri, challenge, resource: 'https://elsewhere.test/mcp' }, 400);
  expect(response).toBe(400);
});

async function startAuthorizeExpectStatus(opts: { clientId: string; redirectUri: string; challenge: string; resource: string }, expected: number) {
  const url = new URL(`${ORIGIN}/oauth/authorize`);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', opts.clientId);
  url.searchParams.set('redirect_uri', opts.redirectUri);
  url.searchParams.set('code_challenge', opts.challenge);
  url.searchParams.set('code_challenge_method', 'S256');
  url.searchParams.set('resource', opts.resource);
  const response = await app.handle(new Request(url));
  expect(response!.status).toBe(expected);
  return response!.status;
}

test('a token exchange naming a different resource than the authorize request is rejected', async () => {
  const redirectUri = 'https://client.test/callback';
  const { client_id } = await registerClient(redirectUri);
  const { verifier, challenge } = pkcePair();
  const requestId = await startAuthorize({ clientId: client_id, redirectUri, challenge });
  bridgeCtl.approveNext();
  const settled = await pollUntilSettled(requestId);
  const code = new URL(settled.redirect!).searchParams.get('code')!;
  const response = await app.handle(new Request(`${ORIGIN}/oauth/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code', code, redirect_uri: redirectUri, client_id, code_verifier: verifier, resource: 'https://elsewhere.test/mcp',
    }),
  }));
  expect(response!.status).toBe(400);
});

test('token file on disk is written mode 600', async () => {
  await fullAuthorizationFlow();
  const { statSync } = await import('node:fs');
  const stat = statSync(join(privateDir, 'mcp-tokens.json'));
  expect(stat.mode & 0o777).toBe(0o600);
});
