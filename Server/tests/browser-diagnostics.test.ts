import { afterEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BodyTooLarge, createBrowserService, readBodyCapped, type BrowserServiceConfig } from '../src/browser/service';

type App = ReturnType<typeof createBrowserService>;
const instances: App[] = [];
const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(instances.map((instance) => instance.stop()));
  instances.length = 0;
  for (const directory of temporaryDirectories) rmSync(directory, { recursive: true, force: true });
  temporaryDirectories.length = 0;
});

function staticFixture() {
  const root = mkdtempSync(join(tmpdir(), 'pocketdesk-browser-diag-static-'));
  temporaryDirectories.push(root);
  mkdirSync(join(root, 'BrowserClient'), { recursive: true });
  return root;
}

function diagDir() {
  const dir = mkdtempSync(join(tmpdir(), 'pocketdesk-browser-diag-out-'));
  temporaryDirectories.push(dir);
  return dir;
}

function setup(config: BrowserServiceConfig = {}) {
  const app = createBrowserService({ staticRoot: staticFixture(), ...config });
  instances.push(app);
  return app;
}

const validReport = () => ({
  userAgent: 'test-agent', viewport: { width: 400, height: 800 }, markerMode: 'crop',
  markerCost: [{ mode: 'crop', drawMs: 0.2, getImageDataMs: 0.1, decodeMs: 0.05, totalMs: 0.35 }],
  bufferedAmount: { max: 0, positiveSends: 0, sends: 3 },
  stats: [{ at: 12, pair: { localAddressClass: 'private-lan', remoteAddressClass: 'public' }, inbound: null, bitrateBps: null }],
  benchSummary: null,
});

describe('readBodyCapped', () => {
  test('throws BodyTooLarge once the cap is exceeded, without draining the whole oversized stream', async () => {
    const cap = 1_000;
    const chunkSize = 100;
    const chunksAvailable = 1_000;
    let pulls = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulls += 1;
        if (pulls > chunksAvailable) { controller.close(); return; }
        controller.enqueue(new Uint8Array(chunkSize).fill(0x78));
      },
    });
    const request = new Request('http://example.test/', { method: 'POST', body: stream, duplex: 'half' } as RequestInit & { duplex: 'half' });
    await expect(readBodyCapped(request, cap)).rejects.toBeInstanceOf(BodyTooLarge);
    // Only enough chunks to cross the cap should ever be pulled (cap / chunkSize + 1 = 11); a bound
    // far below the 1000 available chunks proves the reader stops instead of consuming the rest.
    expect(pulls).toBeLessThan(chunksAvailable / 2);
  });

  test('returns the full body when it is under the cap', async () => {
    const stream = new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(new TextEncoder().encode('hello')); controller.close(); },
    });
    const request = new Request('http://example.test/', { method: 'POST', body: stream, duplex: 'half' } as RequestInit & { duplex: 'half' });
    const bytes = await readBodyCapped(request, 1_000);
    expect(new TextDecoder().decode(bytes)).toBe('hello');
  });
});

describe('browser diagnostics endpoint', () => {
  test('is 404 when no diagnostics directory is configured', async () => {
    const app = setup();
    const origin = `http://127.0.0.1:${app.port}`;
    const response = await fetch(`${origin}/api/diagnostics`, {
      method: 'POST', headers: { 'content-type': 'application/json', origin }, body: JSON.stringify(validReport()),
    });
    expect(response.status).toBe(404);
  });

  test('rejects a mismatched Origin even when a directory is configured', async () => {
    const dir = diagDir();
    const app = setup({ diagnosticsDir: dir });
    const origin = `http://127.0.0.1:${app.port}`;
    const response = await fetch(`${origin}/api/diagnostics`, {
      method: 'POST', headers: { 'content-type': 'application/json', origin: 'https://evil.example' }, body: JSON.stringify(validReport()),
    });
    expect(response.status).toBe(403);
    expect(readdirSync(dir)).toHaveLength(0);
  });

  test('rejects a body over the 512 KiB cap', async () => {
    const dir = diagDir();
    const app = setup({ diagnosticsDir: dir });
    const origin = `http://127.0.0.1:${app.port}`;
    const oversize = { ...validReport(), pad: 'x'.repeat(600 * 1024) };
    const response = await fetch(`${origin}/api/diagnostics`, {
      method: 'POST', headers: { 'content-type': 'application/json', origin }, body: JSON.stringify(oversize),
    });
    expect(response.status).toBe(413);
    expect(readdirSync(dir)).toHaveLength(0);
  });

  test('accepts a valid report, returns 204 and writes exactly one file', async () => {
    const dir = diagDir();
    const app = setup({ diagnosticsDir: dir });
    const origin = `http://127.0.0.1:${app.port}`;
    const response = await fetch(`${origin}/api/diagnostics`, {
      method: 'POST', headers: { 'content-type': 'application/json', origin }, body: JSON.stringify(validReport()),
    });
    expect(response.status).toBe(204);
    const files = readdirSync(dir);
    expect(files).toHaveLength(1);
    expect(files[0]).toMatch(/^diag-.*\.json$/);
    const written = JSON.parse(readFileSync(join(dir, files[0]), 'utf8'));
    expect(written.markerMode).toBe('crop');
  });

  test('caps the streamed body even when Content-Length is missing', async () => {
    const dir = diagDir();
    const app = setup({ diagnosticsDir: dir });
    const origin = `http://127.0.0.1:${app.port}`;
    const bigText = JSON.stringify({ ...validReport(), pad: 'x'.repeat(600 * 1024) });
    const stream = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(new TextEncoder().encode(bigText)); controller.close(); } });
    const response = await fetch(`${origin}/api/diagnostics`, {
      method: 'POST', headers: { 'content-type': 'application/json', origin }, body: stream, duplex: 'half',
    } as RequestInit & { duplex: 'half' });
    expect(response.status).toBe(413);
    expect(readdirSync(dir)).toHaveLength(0);
  });

  test('rejects an oversized body even when Content-Length lies about being small', async () => {
    // fetch() with a ReadableStream body ignores a manually-set Content-Length and sends
    // Transfer-Encoding: chunked instead (confirmed by capturing the raw request bytes on a
    // Bun.listen() socket), so the full oversized body reaches the server and readBodyCapped's
    // streaming cap is what rejects it -- almost always with 413. In rare timing windows, cancelling
    // the reader mid-stream races Bun's own HTTP/1.1 framing (which sees both a stale Content-Length
    // header and Transfer-Encoding: chunked on the wire) and the connection is torn down as a 400
    // before our handler's response is written. Both outcomes correctly refuse the oversized body
    // and write nothing to disk, so both are accepted here instead of pinning a single status code.
    const dir = diagDir();
    const app = setup({ diagnosticsDir: dir });
    const origin = `http://127.0.0.1:${app.port}`;
    const bigText = JSON.stringify({ ...validReport(), pad: 'x'.repeat(600 * 1024) });
    const stream = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(new TextEncoder().encode(bigText)); controller.close(); } });
    const response = await fetch(`${origin}/api/diagnostics`, {
      method: 'POST', headers: { 'content-type': 'application/json', origin, 'content-length': '10' }, body: stream, duplex: 'half',
    } as RequestInit & { duplex: 'half' });
    expect([400, 413]).toContain(response.status);
    expect(readdirSync(dir)).toHaveLength(0);
  });

  test('rejects a report that carries a raw IPv4 address instead of an address class', async () => {
    const dir = diagDir();
    const app = setup({ diagnosticsDir: dir });
    const origin = `http://127.0.0.1:${app.port}`;
    const tainted = { ...validReport(), stats: [{ at: 1, pair: { note: '192.168.1.42' }, inbound: null, bitrateBps: null }] };
    const response = await fetch(`${origin}/api/diagnostics`, {
      method: 'POST', headers: { 'content-type': 'application/json', origin }, body: JSON.stringify(tainted),
    });
    expect(response.status).toBe(400);
    expect(readdirSync(dir)).toHaveLength(0);
  });

  test('rejects a report that carries a raw IPv6 address instead of an address class', async () => {
    const dir = diagDir();
    const app = setup({ diagnosticsDir: dir });
    const origin = `http://127.0.0.1:${app.port}`;
    const tainted = { ...validReport(), stats: [{ at: 1, pair: { note: 'fe80::1a2b:3c4d' }, inbound: null, bitrateBps: null }] };
    const response = await fetch(`${origin}/api/diagnostics`, {
      method: 'POST', headers: { 'content-type': 'application/json', origin }, body: JSON.stringify(tainted),
    });
    expect(response.status).toBe(400);
    expect(readdirSync(dir)).toHaveLength(0);
  });

  test('does not mistake an ISO timestamp for a raw IPv6 address', async () => {
    const dir = diagDir();
    const app = setup({ diagnosticsDir: dir });
    const origin = `http://127.0.0.1:${app.port}`;
    const report = { ...validReport(), stats: [{ at: 1, capturedAt: '2026-09-14T10:44:36.123Z', pair: null, inbound: null, bitrateBps: null }] };
    const response = await fetch(`${origin}/api/diagnostics`, {
      method: 'POST', headers: { 'content-type': 'application/json', origin }, body: JSON.stringify(report),
    });
    expect(response.status).toBe(204);
    expect(readdirSync(dir)).toHaveLength(1);
  });

  test('rejects the wrong content type and a non-JSON-object body', async () => {
    const dir = diagDir();
    const app = setup({ diagnosticsDir: dir });
    const origin = `http://127.0.0.1:${app.port}`;
    const wrongType = await fetch(`${origin}/api/diagnostics`, { method: 'POST', headers: { 'content-type': 'text/plain', origin }, body: JSON.stringify(validReport()) });
    expect(wrongType.status).toBe(415);
    const notObject = await fetch(`${origin}/api/diagnostics`, { method: 'POST', headers: { 'content-type': 'application/json', origin }, body: JSON.stringify([1, 2, 3]) });
    expect(notObject.status).toBe(400);
    expect(readdirSync(dir)).toHaveLength(0);
  });

  test('a non-POST method is not found even when enabled', async () => {
    const app = setup({ diagnosticsDir: diagDir() });
    const origin = `http://127.0.0.1:${app.port}`;
    expect((await fetch(`${origin}/api/diagnostics`, { headers: { origin } })).status).toBe(404);
  });
});
