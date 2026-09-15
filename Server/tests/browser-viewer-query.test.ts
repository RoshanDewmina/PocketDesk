import { afterEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBrowserService, type BrowserServiceConfig } from '../src/browser/service';

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
  const root = mkdtempSync(join(tmpdir(), 'pocketdesk-browser-query-static-'));
  temporaryDirectories.push(root);
  mkdirSync(join(root, 'BrowserClient'), { recursive: true });
  writeFileSync(join(root, 'BrowserClient/index.html'), '<!doctype html><script type="module" src="/app.js"></script>');
  writeFileSync(join(root, 'BrowserClient/app.js'), 'export const app = true;');
  return root;
}

function setup(config: BrowserServiceConfig = {}) {
  const app = createBrowserService({ staticRoot: staticFixture(), ...config });
  instances.push(app);
  return app;
}

describe('viewer document query allowlist', () => {
  test('accepts allowed diagnostics query combinations on the viewer document', async () => {
    const app = setup();
    const origin = `http://127.0.0.1:${app.port}`;
    const allowed = ['?diag=1', '?marker=crop', '?marker=full', '?diag=1&marker=full&bench=50&tile=1,2,3,4'];
    for (const query of allowed) {
      const response = await fetch(`${origin}/${query}`);
      expect(response.status).toBe(200);
    }
  });

  test('rejects an unknown key', async () => {
    const app = setup();
    const response = await fetch(`http://127.0.0.1:${app.port}/?foo=1`);
    expect(response.status).toBe(404);
  });

  test('rejects a bad value for a known key', async () => {
    const app = setup();
    const origin = `http://127.0.0.1:${app.port}`;
    expect((await fetch(`${origin}/?bench=abc`)).status).toBe(404);
    expect((await fetch(`${origin}/?bench=0`)).status).toBe(404);
    expect((await fetch(`${origin}/?bench=1001`)).status).toBe(404);
    expect((await fetch(`${origin}/?marker=something-else`)).status).toBe(404);
    expect((await fetch(`${origin}/?diag=true`)).status).toBe(404);
    expect((await fetch(`${origin}/?tile=1,2,3`)).status).toBe(404);
    expect((await fetch(`${origin}/?tile=-1,2,3,4`)).status).toBe(404);
  });

  test('rejects a duplicated key', async () => {
    const app = setup();
    const response = await fetch(`http://127.0.0.1:${app.port}/?diag=1&diag=1`);
    expect(response.status).toBe(404);
  });

  test('a query string on a static asset is still not found', async () => {
    const app = setup();
    const response = await fetch(`http://127.0.0.1:${app.port}/app.js?diag=1`);
    expect(response.status).toBe(404);
  });

  test('a query string on the diagnostics API is still not found', async () => {
    const app = setup({ diagnosticsDir: mkdtempSync(join(tmpdir(), 'pocketdesk-browser-query-diag-')) });
    temporaryDirectories.push(...[]);
    const origin = `http://127.0.0.1:${app.port}`;
    const response = await fetch(`${origin}/api/diagnostics?diag=1`, {
      method: 'POST', headers: { 'content-type': 'application/json', origin }, body: '{}',
    });
    expect(response.status).toBe(404);
  });

  test('a query string on a browser-api route is still not found', async () => {
    const app = setup();
    const origin = `http://127.0.0.1:${app.port}`;
    const response = await fetch(`${origin}/browser-api/${'a'.repeat(64)}/challenge?diag=1`, {
      method: 'POST', headers: { 'content-type': 'application/json', origin }, body: '{}',
    });
    expect(response.status).toBe(404);
  });

  test('a POST to the viewer document with an otherwise-allowed query is still not found (GET/HEAD only)', async () => {
    const app = setup();
    const response = await fetch(`http://127.0.0.1:${app.port}/?diag=1`, { method: 'POST' });
    expect(response.status).toBe(404);
  });
});
