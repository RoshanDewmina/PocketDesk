import { expect, test } from 'bun:test';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parsePrivateEnvFile, summarizeIce } from '../scripts/readiness';

test('readiness summarizes client-safe ICE without credentials', () => {
  expect(summarizeIce([
    { urls: ['stun:stun.cloudflare.com:3478'] },
    { urls: ['turn:turn.cloudflare.com:3478?transport=udp'], username: 'secret-user', credential: 'secret-credential' },
  ])).toEqual({ serverCount: 2, urlCount: 2, transports: ['stun', 'turn'] });
  expect(() => summarizeIce([{ urls: ['stun:only.example.test'] }])).toThrow('no TURN relay');
});

test('readiness reads only a private regular environment file', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pocketdesk-env-'));
  const path = join(directory, 'service.env');
  try {
    writeFileSync(path, 'NODE_ENV=production\nPORT="28787"\n', { mode: 0o600 });
    chmodSync(path, 0o600);
    expect(parsePrivateEnvFile(path)).toEqual({ NODE_ENV: 'production', PORT: '28787' });
    chmodSync(path, 0o644);
    expect(() => parsePrivateEnvFile(path)).toThrow('private regular file');
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
