import { afterEach, expect, setSystemTime, test } from 'bun:test';
import { loadServiceConfig } from '../src/config';
import { createService, digest } from '../src/server';
import { createCloudflareTurnProvider, defaultRevocationRetry, revocationDelayMs, revocationPropagationMs } from '../src/turn';

const keyId = 'k'.repeat(32);
const apiToken = 't'.repeat(64);
const instances: ReturnType<typeof createService>[] = [];
afterEach(async () => {
  setSystemTime();
  await Promise.all(instances.map(app => app.stop(100)));
  instances.length = 0;
});

type Recorded = { url: string; method?: string; authorization: string | null; body: string | null };

function cloudflareMock(options: { generate?: () => Response | Promise<Response>; revoke?: () => Response } = {}) {
  const calls: Recorded[] = [];
  let issued = 0;
  const fetch: typeof globalThis.fetch = async (input, init) => {
    const url = String(input);
    calls.push({ url, method: init?.method, authorization: new Headers(init?.headers).get('authorization'), body: init?.body ? String(init.body) : null });
    if (url.endsWith('/generate-ice-servers')) {
      if (options.generate) {
        return Promise.race([
          Promise.resolve(options.generate()),
          new Promise<Response>((_resolve, reject) => {
            init?.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
          }),
        ]);
      }
      issued += 1;
      return Response.json({ iceServers: [
        { urls: ['stun:stun.cloudflare.com:3478'] },
        { urls: ['turn:turn.cloudflare.com:3478?transport=udp', 'turns:turn.cloudflare.com:443?transport=tcp'], username: `user-${issued}`, credential: `credential-${issued}` },
      ] }, { status: 201 });
    }
    return options.revoke ? options.revoke() : new Response(null, { status: 204 });
  };
  return { calls, fetch };
}

function provider(fetch: typeof globalThis.fetch, overrides: {
  ttlSeconds?: number; timeoutMs?: number; log?: (line: string) => void; sleeps?: number[];
} = {}) {
  return createCloudflareTurnProvider({
    keyId, apiToken, ttlSeconds: overrides.ttlSeconds ?? 3600, timeoutMs: overrides.timeoutMs ?? 100, fetch,
    sleep: async ms => { overrides.sleeps?.push(ms); },
    random: () => 0.5,
    log: overrides.log ?? (() => {}),
  });
}

/** Answers each revoke call from a script: a status (with an optional body) or a thrown network error. */
function revokeScript(steps: (number | 'network' | { status: number; body: string })[]) {
  const calls: string[] = [];
  const fetch: typeof globalThis.fetch = async input => {
    const url = String(input);
    calls.push(url.split('/credentials/')[1] ?? url);
    const step = steps.length > 1 ? steps.shift()! : steps[0];
    if (step === 'network') throw new TypeError(`fetch failed for ${url}`);
    if (typeof step === 'number') return new Response(null, { status: step });
    return new Response(step.body, { status: step.status });
  };
  return { calls, fetch };
}

function peer(app: ReturnType<typeof createService>) {
  const ws = new WebSocket(`ws://127.0.0.1:${app.server.port}/signal`);
  const messages: any[] = [];
  const waiters: ((value: any) => void)[] = [];
  ws.onmessage = event => {
    const value = JSON.parse(String(event.data));
    const waiter = waiters.shift();
    if (waiter) waiter(value); else messages.push(value);
  };
  const open = new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = reject; });
  const next = () => messages.length ? Promise.resolve(messages.shift()) : new Promise<any>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('message timeout')), 2000);
    waiters.push(value => { clearTimeout(timer); resolve(value); });
  });
  return { ws, open, next, send: (value: unknown) => ws.send(JSON.stringify(value)) };
}

function pair(letter: string) {
  const hostToken = letter.repeat(64);
  const clientToken = letter === 'a' ? 'b'.repeat(64) : 'a'.repeat(64);
  const room = digest(hostToken);
  return {
    room,
    clientToken,
    host: { type: 'register', version: 1, role: 'host', room, token: hostToken, clientTokenHash: digest(clientToken) },
    client: { type: 'register', version: 1, role: 'client', room, token: clientToken },
  };
}

async function registerHost(app: ReturnType<typeof createService>, letter = 'a') {
  const p = pair(letter);
  const host = peer(app);
  await host.open;
  host.send(p.host);
  const registered = await host.next();
  return { host, p, registered };
}

async function ready(app: ReturnType<typeof createService>) {
  const response = await fetch(`http://127.0.0.1:${app.server.port}/ready`);
  return { status: response.status, text: await response.text() };
}

test('every authenticated peer gets its own short-lived Cloudflare credential with the configured TTL', async () => {
  const mock = cloudflareMock();
  const app = createService({ port: 0, turnProvider: provider(mock.fetch, { ttlSeconds: 3600 }) });
  instances.push(app);
  const { host, p } = await registerHost(app);
  const hostIce = await host.next();
  const client = peer(app);
  await client.open;
  client.send(p.client);
  expect((await client.next()).type).toBe('registered');
  const clientIce = await client.next();

  const generates = mock.calls.filter(call => call.url.endsWith('/generate-ice-servers'));
  expect(generates).toHaveLength(2);
  for (const call of generates) {
    expect(call.url).toBe(`https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate-ice-servers`);
    expect(call.method).toBe('POST');
    expect(call.authorization).toBe(`Bearer ${apiToken}`);
    expect(JSON.parse(call.body!)).toEqual({ ttl: 3600 });
  }
  expect(hostIce.servers[1].username).toBe('user-1');
  expect(clientIce.servers[1].username).toBe('user-2');
  expect(JSON.stringify([hostIce, clientIce])).not.toContain(apiToken);
  expect(hostIce.policy).toBeUndefined();
});

test('each credential is revoked exactly once on disconnect and never appears in readiness output', async () => {
  const mock = cloudflareMock();
  const app = createService({ port: 0, turnProvider: provider(mock.fetch) });
  instances.push(app);
  const { host, p } = await registerHost(app);
  await host.next();
  const client = peer(app);
  await client.open;
  client.send(p.client);
  await client.next(); await client.next();
  const during = await ready(app);
  expect(during.text).not.toContain('user-1');
  expect(during.text).not.toContain('credential-1');
  expect(during.text).not.toContain(p.room);
  expect(during.text).not.toContain(apiToken);
  client.ws.close();
  host.ws.close();
  await new Promise(resolve => setTimeout(resolve, 50));
  const revokes = mock.calls.filter(call => call.url.endsWith('/revoke')).map(call => call.url);
  expect(revokes.sort()).toEqual([
    `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/user-1/revoke`,
    `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/user-2/revoke`,
  ]);
});

test('credential issuance is capped per minute, counted in readiness, and recovers when the window rolls', async () => {
  const mock = cloudflareMock();
  const app = createService({ port: 0, turnProvider: provider(mock.fetch), credentialIssuesPerMinute: 2 });
  instances.push(app);
  const first = await registerHost(app, 'a');
  expect(first.registered.type).toBe('registered');
  await first.host.next();
  const second = await registerHost(app, 'c');
  expect(second.registered.type).toBe('registered');
  await second.host.next();
  const third = await registerHost(app, 'd');
  expect(third.registered.code).toBe('relay_unavailable');
  expect(mock.calls.filter(call => call.url.endsWith('/generate-ice-servers'))).toHaveLength(2);
  expect(JSON.parse((await ready(app)).text).relay.issuanceRateLimited).toBe(1);

  setSystemTime(new Date(Date.now() + 61_000));
  const retry = await registerHost(app, 'd');
  expect(retry.registered.type).toBe('registered');
});

test('the shipped relay policy of 8 issues per minute admits exactly four sessions per minute', async () => {
  const mock = cloudflareMock();
  const app = createService({ port: 0, turnProvider: provider(mock.fetch), credentialIssuesPerMinute: 8, maxPeers: 4 });
  instances.push(app);
  let issued = 0;
  for (const letter of ['a', 'c', 'd', 'e']) {
    const { host, registered } = await registerHost(app, letter);
    expect(registered.type).toBe('registered');
    await host.next();
    issued += 1;
    host.ws.close();
  }
  expect(issued).toBe(4);
});

test('provider rejection, malformed output, relay-less output, and hangs all fail registration closed without leaking the token', async () => {
  const cases: [string, () => Response | Promise<Response>][] = [
    ['unauthorized', () => new Response('nope', { status: 401 })],
    ['malformed', () => new Response('{', { status: 201 })],
    ['stun only', () => Response.json({ iceServers: [{ urls: ['stun:stun.cloudflare.com:3478'] }] }, { status: 201 })],
    ['missing credentials', () => Response.json({ iceServers: [{ urls: ['turn:turn.cloudflare.com:3478'] }] }, { status: 201 })],
    ['hang', () => new Promise<Response>(() => {})],
  ];
  for (const [label, generate] of cases) {
    const mock = cloudflareMock({ generate });
    const failing = provider(mock.fetch, { timeoutMs: 50 });
    const failure = await failing.issue({ room: pair('a').room, role: 'host' }).catch(error => error as Error);
    expect(failure.message, label).toBe('TURN credential provider unavailable');
    expect(failure.message).not.toContain(apiToken);

    const app = createService({ port: 0, turnProvider: provider(mock.fetch, { timeoutMs: 50 }), relayTimeoutMs: 100 });
    instances.push(app);
    const { registered } = await registerHost(app);
    expect(registered.code, label).toBe('relay_unavailable');
    expect(app.roomCount()).toBe(0);
  }
});

test('readiness is 503 without a relay, 200 with a healthy relay, and 503 after three consecutive provider failures', async () => {
  const bare = createService({ port: 0 });
  instances.push(bare);
  const missing = await ready(bare);
  expect(missing.status).toBe(503);
  expect(JSON.parse(missing.text)).toMatchObject({ status: 'not_ready', reasons: ['relay_not_configured'], relay: { provider: 'none', policy: 'all' } });

  let failing = false;
  const mock = cloudflareMock({ generate: () => (failing
    ? new Response('nope', { status: 500 })
    : Response.json({ iceServers: [{ urls: ['turn:turn.cloudflare.com:3478'], username: 'u', credential: 'c' }] }, { status: 201 })) });
  const app = createService({ port: 0, turnProvider: provider(mock.fetch) });
  instances.push(app);
  expect(JSON.parse((await ready(app)).text).relay.lastIssue).toBe('none');
  const first = await registerHost(app, 'a');
  await first.host.next();
  const healthy = await ready(app);
  expect(healthy.status).toBe(200);
  expect(JSON.parse(healthy.text)).toMatchObject({ status: 'ready', reasons: [], relay: { provider: 'cloudflare', lastIssue: 'ok', consecutiveFailures: 0 }, approval: 'open', rooms: 1 });

  failing = true;
  for (const letter of ['c', 'd', 'e']) expect((await registerHost(app, letter)).registered.code).toBe('relay_unavailable');
  const degraded = await ready(app);
  expect(degraded.status).toBe(503);
  expect(JSON.parse(degraded.text)).toMatchObject({ status: 'not_ready', reasons: ['relay_provider_failing'], relay: { lastIssue: 'failed', consecutiveFailures: 3 } });

  failing = false;
  const recovered = await registerHost(app, 'f');
  expect(recovered.registered.type).toBe('registered');
  expect((await ready(app)).status).toBe(200);
});

test('health stays a bare liveness answer and readiness rejects non-GET methods', async () => {
  const app = createService({ port: 0 });
  instances.push(app);
  const origin = `http://127.0.0.1:${app.server.port}`;
  expect(await (await fetch(`${origin}/health`)).json()).toEqual({ status: 'ok', protocol: 1 });
  expect((await fetch(`${origin}/ready`, { method: 'POST' })).status).toBe(404);
});

test('forced-relay test mode marks the ICE message for both peers and is reported by readiness', async () => {
  const mock = cloudflareMock();
  const app = createService({ port: 0, turnProvider: provider(mock.fetch), testForceRelay: true });
  instances.push(app);
  const { host, p } = await registerHost(app);
  const hostIce = await host.next();
  const client = peer(app);
  await client.open;
  client.send(p.client);
  await client.next();
  const clientIce = await client.next();
  expect(hostIce).toMatchObject({ type: 'ice', policy: 'relay' });
  expect(clientIce).toMatchObject({ type: 'ice', policy: 'relay' });
  expect(JSON.parse((await ready(app)).text).relay.policy).toBe('relay');
});

test('forced-relay test mode cannot be enabled without a relay provider', () => {
  expect(() => createService({ port: 0, testForceRelay: true })).toThrow('testForceRelay requires a relay provider');
  expect(() => loadServiceConfig({ POCKETDESK_TEST_FORCE_RELAY: '1' })).toThrow('POCKETDESK_TEST_FORCE_RELAY requires TURN_PROVIDER');
  expect(() => loadServiceConfig({ POCKETDESK_TEST_FORCE_RELAY: 'maybe', TURN_PROVIDER: 'cloudflare', CLOUDFLARE_TURN_KEY_ID: keyId, CLOUDFLARE_TURN_KEY_API_TOKEN: apiToken }))
    .toThrow('POCKETDESK_TEST_FORCE_RELAY must be 0, 1, true, or false');
  const env = { TURN_PROVIDER: 'cloudflare', CLOUDFLARE_TURN_KEY_ID: keyId, CLOUDFLARE_TURN_KEY_API_TOKEN: apiToken };
  expect(loadServiceConfig({ ...env, POCKETDESK_TEST_FORCE_RELAY: '1' }).testForceRelay).toBe(true);
  expect(loadServiceConfig({ ...env, POCKETDESK_TEST_FORCE_RELAY: '0' }).testForceRelay).toBe(false);
  expect(loadServiceConfig(env).testForceRelay).toBe(false);
});

test('revocation issues one call per distinct username and treats any non-204 as a failure', async () => {
  const mock = cloudflareMock();
  await provider(mock.fetch).revoke!([
    { urls: ['turn:turn.cloudflare.com:3478'], username: 'same', credential: 'c1' },
    { urls: ['turns:turn.cloudflare.com:443'], username: 'same', credential: 'c1' },
    { urls: ['turn:turn.cloudflare.com:3478'], username: 'other', credential: 'c2' },
    { urls: ['stun:stun.cloudflare.com:3478'] },
  ]);
  expect(mock.calls.map(call => call.url.split('/credentials/')[1])).toEqual(['same/revoke', 'other/revoke']);
  const rejecting = cloudflareMock({ revoke: () => new Response(null, { status: 404 }) });
  await expect(provider(rejecting.fetch).revoke!([{ urls: ['turn:turn.cloudflare.com:3478'], username: 'gone', credential: 'c' }]))
    .rejects.toThrow('TURN credential revocation rejected');
});

test('a revocation that Cloudflare rejects once is retried after a jittered backoff and succeeds', async () => {
  const script = revokeScript([{ status: 502, body: `{"errors":[{"message":"upstream","key":"${apiToken}","user":"secret-user"}]}` }, 204]);
  const lines: string[] = [];
  const sleeps: number[] = [];
  await provider(script.fetch, { log: line => lines.push(line), sleeps })
    .revoke!([{ urls: ['turn:turn.cloudflare.com:3478'], username: 'secret-user', credential: 'secret-credential' }]);
  expect(script.calls).toEqual(['secret-user/revoke', 'secret-user/revoke']);
  expect(sleeps).toEqual([revocationDelayMs(1, defaultRevocationRetry, () => 0.5)]);
  expect(lines.join('\n')).toContain('attempt 1 of 4 failed: status 502 body');
  expect(lines.join('\n')).toContain('upstream');
  expect(lines.join('\n')).toContain('revoked on attempt 2');
  for (const secret of [apiToken, keyId, 'secret-user', 'secret-credential']) expect(lines.join('\n')).not.toContain(secret);
});

test('a revocation that keeps failing stops after the bounded attempts, still revokes the others, and rejects', async () => {
  const failing = new Set(['stuck']);
  const calls: string[] = [];
  const fetch: typeof globalThis.fetch = async input => {
    const name = String(input).split('/credentials/')[1]!.split('/')[0]!;
    calls.push(name);
    if (!failing.has(name)) return new Response(null, { status: 204 });
    if (calls.filter(call => call === name).length % 2) throw new TypeError(`fetch failed for ${String(input)}`);
    return new Response('rate limited', { status: 429 });
  };
  const lines: string[] = [];
  const sleeps: number[] = [];
  await expect(provider(fetch, { log: line => lines.push(line), sleeps }).revoke!([
    { urls: ['turn:turn.cloudflare.com:3478'], username: 'stuck', credential: 'c1' },
    { urls: ['turn:turn.cloudflare.com:3478'], username: 'fine', credential: 'c2' },
  ])).rejects.toThrow('TURN credential revocation rejected');
  expect(calls).toEqual(['stuck', 'stuck', 'stuck', 'stuck', 'fine']);
  expect(sleeps).toHaveLength(3);
  expect(sleeps.every((ms, index) => ms > 0 && ms <= defaultRevocationRetry.maxDelayMs && (index === 0 || ms >= sleeps[index - 1]!))).toBe(true);
  const log = lines.join('\n');
  expect(log).toContain('request failed (TypeError)');
  expect(log).toContain('status 429 body "rate limited"');
  expect(log).toContain('not revoked after 4 attempts');
  expect(log).not.toContain('stuck');
  expect(log).not.toContain(apiToken);
});

test('the backoff doubles up to its ceiling and jitters between half and all of it', () => {
  const retry = { attempts: 6, baseDelayMs: 100, maxDelayMs: 500 };
  expect([1, 2, 3, 4, 5].map(attempt => revocationDelayMs(attempt, retry, () => 1))).toEqual([100, 200, 400, 500, 500]);
  expect([1, 2, 3].map(attempt => revocationDelayMs(attempt, retry, () => 0))).toEqual([50, 100, 200]);
  const noFetch = (async () => { throw new Error('must not be called'); }) as unknown as typeof globalThis.fetch;
  expect(() => createCloudflareTurnProvider({ keyId, apiToken, ttlSeconds: 3600, timeoutMs: 100, fetch: noFetch,
    revocationRetry: { attempts: 0, baseDelayMs: 1, maxDelayMs: 1 } })).toThrow('invalid Cloudflare revocation retry policy');
});

const notFound = { status: 404, body: '{"error":"cannot find specified username"}' };
const credential = { urls: ['turn:turn.cloudflare.com:3478'], username: 'u-1', credential: 'c-1' };

test('a 404 right after issue is the credential not having propagated yet: retried until it revokes', async () => {
  const script = revokeScript([notFound, 204]);
  const lines: string[] = [];
  await provider(script.fetch, { log: line => lines.push(line) }).revoke!([credential], { ageMs: 400 });
  expect(script.calls).toEqual(['u-1/revoke', 'u-1/revoke']);
  expect(lines.join('\n')).toContain('attempt 1 of 4 failed: status 404 body "{"error":"cannot find specified username"}"');
  expect(lines.join('\n')).toContain('revoked on attempt 2');
});

test('a 404 that persists while the credential is still new counts as a failure', async () => {
  const script = revokeScript([notFound]);
  await expect(provider(script.fetch).revoke!([credential], { ageMs: 1_000 })).rejects.toThrow('TURN credential revocation rejected');
  expect(script.calls).toHaveLength(defaultRevocationRetry.attempts);
});

test('a 404 long after issue means already revoked or expired: done at once, not a failure', async () => {
  const script = revokeScript([notFound]);
  const lines: string[] = [];
  await provider(script.fetch, { log: line => lines.push(line) })
    .revoke!([credential], { ageMs: revocationPropagationMs + 5_000 });
  expect(script.calls).toEqual(['u-1/revoke']);
  expect(lines.join('\n')).toContain('not found 35 s after issue; already revoked or expired');
  expect(lines.join('\n')).not.toContain('u-1');
});

test('a 404 with no known issue time is never taken as done', async () => {
  const script = revokeScript([notFound]);
  await expect(provider(script.fetch).revoke!([credential])).rejects.toThrow('TURN credential revocation rejected');
  expect(script.calls).toHaveLength(defaultRevocationRetry.attempts);
});

test('a set revoked more than 30 s after issue does not count a 404 in readiness; a new set does', async () => {
  const mock = cloudflareMock({ revoke: () => new Response('{"error":"cannot find specified username"}', { status: 404 }) });
  const app = createService({ port: 0, turnProvider: provider(mock.fetch) });
  instances.push(app);
  const old = await registerHost(app, 'a');
  await old.host.next();
  setSystemTime(new Date(Date.now() + revocationPropagationMs + 1_000));
  old.host.ws.close();
  await new Promise(resolve => setTimeout(resolve, 50));
  expect(mock.calls.filter(call => call.url.endsWith('/revoke'))).toHaveLength(1);
  expect(JSON.parse((await ready(app)).text).relay.revocationFailures).toBe(0);

  const fresh = await registerHost(app, 'c');
  await fresh.host.next();
  fresh.host.ws.close();
  await new Promise(resolve => setTimeout(resolve, 50));
  expect(JSON.parse((await ready(app)).text).relay.revocationFailures).toBe(1);
});

test('retry lines go to stderr, never stdout, by default', async () => {
  const script = revokeScript([notFound, 204]);
  const written: { stream: string; text: string }[] = [];
  const stdoutWrite = process.stdout.write.bind(process.stdout);
  const stderrWrite = process.stderr.write.bind(process.stderr);
  process.stdout.write = ((chunk: any) => { written.push({ stream: 'stdout', text: String(chunk) }); return true; }) as typeof process.stdout.write;
  process.stderr.write = ((chunk: any) => { written.push({ stream: 'stderr', text: String(chunk) }); return true; }) as typeof process.stderr.write;
  try {
    await createCloudflareTurnProvider({ keyId, apiToken, ttlSeconds: 3600, timeoutMs: 100, fetch: script.fetch, sleep: async () => {} })
      .revoke!([credential], { ageMs: 0 });
  } finally {
    process.stdout.write = stdoutWrite;
    process.stderr.write = stderrWrite;
  }
  expect(written.filter(item => item.stream === 'stdout')).toEqual([]);
  expect(written.some(item => item.stream === 'stderr' && item.text.includes('TURN revocation'))).toBe(true);
});

test('readiness counts revocations that failed after their retries', async () => {
  const mock = cloudflareMock({ revoke: () => new Response(null, { status: 500 }) });
  const app = createService({ port: 0, turnProvider: provider(mock.fetch) });
  instances.push(app);
  const { host } = await registerHost(app);
  await host.next();
  expect(JSON.parse((await ready(app)).text).relay.revocationFailures).toBe(0);
  host.ws.close();
  await new Promise(resolve => setTimeout(resolve, 50));
  expect(mock.calls.filter(call => call.url.endsWith('/revoke'))).toHaveLength(defaultRevocationRetry.attempts);
  expect(JSON.parse((await ready(app)).text).relay.revocationFailures).toBe(1);
});

test('the Cloudflare provider validates key, token, TTL and timeout before any request', () => {
  const noFetch = (async () => { throw new Error('must not be called'); }) as unknown as typeof globalThis.fetch;
  const base = { keyId, apiToken, ttlSeconds: 3600, timeoutMs: 3000, fetch: noFetch };
  expect(() => createCloudflareTurnProvider({ ...base, keyId: 'short' })).toThrow('invalid Cloudflare TURN key ID');
  expect(() => createCloudflareTurnProvider({ ...base, keyId: `${'k'.repeat(31)}/` })).toThrow('invalid Cloudflare TURN key ID');
  expect(() => createCloudflareTurnProvider({ ...base, apiToken: 't'.repeat(63) })).toThrow('invalid Cloudflare TURN API token');
  expect(() => createCloudflareTurnProvider({ ...base, ttlSeconds: 59 })).toThrow('invalid Cloudflare credential TTL');
  expect(() => createCloudflareTurnProvider({ ...base, ttlSeconds: 86_401 })).toThrow('invalid Cloudflare credential TTL');
  expect(() => createCloudflareTurnProvider({ ...base, timeoutMs: 0 })).toThrow('invalid Cloudflare provider timeout');
  expect(() => createCloudflareTurnProvider({ ...base, timeoutMs: 10_001 })).toThrow('invalid Cloudflare provider timeout');
  expect(createCloudflareTurnProvider(base).kind).toBe('cloudflare');
});

test('configuration keeps the room shorter than the credential and the service inside safe bounds', () => {
  const env = { TURN_PROVIDER: 'cloudflare', CLOUDFLARE_TURN_KEY_ID: keyId, CLOUDFLARE_TURN_KEY_API_TOKEN: apiToken };
  expect(() => loadServiceConfig({ ...env, TURN_CREDENTIAL_TTL_SECONDS: '600', ROOM_LIFETIME_SECONDS: '600' })).toThrow('ROOM_LIFETIME_SECONDS must be lower than TURN_CREDENTIAL_TTL_SECONDS');
  expect(() => loadServiceConfig({ ...env, TURN_CREDENTIAL_TTL_SECONDS: '59' })).toThrow('TURN_CREDENTIAL_TTL_SECONDS');
  expect(() => loadServiceConfig({ ...env, TURN_CREDENTIAL_TTL_SECONDS: '86401' })).toThrow('TURN_CREDENTIAL_TTL_SECONDS');
  expect(() => loadServiceConfig({ ...env, TURN_CREDENTIAL_ISSUES_PER_MINUTE: '1' })).toThrow('TURN_CREDENTIAL_ISSUES_PER_MINUTE');
  expect(() => loadServiceConfig({ ...env, TURN_CREDENTIAL_ISSUES_PER_MINUTE: '121' })).toThrow('TURN_CREDENTIAL_ISSUES_PER_MINUTE');
  expect(() => loadServiceConfig({ ...env, MAX_PEERS: '1' })).toThrow('MAX_PEERS');
  expect(() => loadServiceConfig({ ...env, TURN_PROVIDER_TIMEOUT_MS: '249' })).toThrow('TURN_PROVIDER_TIMEOUT_MS');
  const config = loadServiceConfig({ ...env, TURN_CREDENTIAL_TTL_SECONDS: '7200', ROOM_LIFETIME_SECONDS: '3600', TURN_CREDENTIAL_ISSUES_PER_MINUTE: '8', MAX_PEERS: '4' });
  expect(config.credentialIssuesPerMinute).toBe(8);
  expect(config.maxPeers).toBe(4);
  expect(config.maxRoomLifetimeMs).toBe(3_600_000);
});

test('the service refuses to issue credentials for a rejected room before calling Cloudflare', async () => {
  const mock = cloudflareMock();
  const app = createService({ port: 0, turnProvider: provider(mock.fetch), allowedRooms: ['f'.repeat(64)] });
  instances.push(app);
  const { registered } = await registerHost(app);
  expect(registered.code).toBe('room_not_approved');
  expect(mock.calls).toHaveLength(0);
});
