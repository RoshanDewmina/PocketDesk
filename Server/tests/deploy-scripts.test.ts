import { afterEach, beforeEach, expect, test } from 'bun:test';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { initRelayHome, setEnvValue } from '../scripts/relay-env';

const scripts = resolve(import.meta.dir, '..', 'scripts');
const realCloudflared = Bun.which('cloudflared');
const keyId = 'k'.repeat(32);
const apiToken = 't'.repeat(64);
let sandbox: string;
let home: string;
let stubs: string;
let logFile: string;
let keychainFile: string;
let tunnelsFile: string;

beforeEach(() => {
  sandbox = mkdtempSync(join(tmpdir(), 'pocketdesk-deploy-'));
  home = join(sandbox, 'home');
  stubs = join(sandbox, 'bin');
  logFile = join(sandbox, 'calls.log');
  keychainFile = join(sandbox, 'keychain.txt');
  tunnelsFile = join(sandbox, 'tunnels.json');
  mkdirSync(home, { recursive: true });
  mkdirSync(stubs);
  writeFileSync(logFile, '');
  writeFileSync(keychainFile, '');
  writeFileSync(tunnelsFile, '[]');
  writeStub('security', `
echo "security $*" >> "$STUB_LOG"
if [ "$1" = find-generic-password ]; then
  service=
  while [ "$#" -gt 0 ]; do if [ "$1" = -s ]; then service=$2; fi; shift; done
  grep -qx "$service" "$STUB_KEYCHAIN" && exit 0
  exit 44
fi
exit 0`);
  writeStub('cloudflared', `
echo "cloudflared $*" >> "$STUB_LOG"
case "$*" in
  *"tunnel list"*) cat "$STUB_TUNNELS"; exit 0 ;;
  *ingress*) exec "$REAL_CLOUDFLARED" "$@" ;;
  *"tunnel create"*)
    for last in "$@"; do :; done
    printf '[{"id":"6ff42ae2-765d-4adf-8112-31c55c1551ef","name":"%s"}]' "$last" > "$STUB_TUNNELS"
    mkdir -p "$HOME/.cloudflared"
    echo '{}' > "$HOME/.cloudflared/6ff42ae2-765d-4adf-8112-31c55c1551ef.json"
    chmod 644 "$HOME/.cloudflared/6ff42ae2-765d-4adf-8112-31c55c1551ef.json"
    exit 0 ;;
esac
exit 0`);
  writeStub('launchctl', `
echo "launchctl $*" >> "$STUB_LOG"
if [ "$1" = print ] && [ -z "\${STUB_LOADED:-}" ]; then exit 1; fi
exit 0`);
});

afterEach(() => { rmSync(sandbox, { recursive: true, force: true }); });

function writeStub(name: string, body: string) {
  const path = join(stubs, name);
  writeFileSync(path, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  chmodSync(path, 0o755);
}

function freePort() {
  const listener = Bun.listen({ hostname: '127.0.0.1', port: 0, socket: { data() {} } });
  const port = listener.port;
  listener.stop(true);
  return port;
}

function prepare(options: { source: 'keychain' | 'env'; keychainItems?: string[]; cert?: boolean }) {
  const relayHome = join(home, '.pocketdesk', 'relay');
  const result = initRelayHome({ host: 'relay.pocketdesk-test.dev', env: { HOME: home, POCKETDESK_HOME: relayHome } });
  setEnvValue(result.envFile, 'PORT', String(freePort()));
  setEnvValue(result.envFile, 'POCKETDESK_SECRET_SOURCE', options.source);
  if (options.source === 'env') {
    writeFileSync(result.envFile, `${readFileSync(result.envFile, 'utf8')}CLOUDFLARE_TURN_KEY_ID=${keyId}\nCLOUDFLARE_TURN_KEY_API_TOKEN=${apiToken}\n`, { mode: 0o600 });
  }
  writeFileSync(keychainFile, `${(options.keychainItems ?? []).join('\n')}\n`);
  if (options.cert) {
    mkdirSync(join(home, '.cloudflared'), { recursive: true });
    writeFileSync(join(home, '.cloudflared', 'cert.pem'), 'stub');
  }
  return result;
}

async function run(script: string, args: string[] = [], extraEnv: Record<string, string> = {}) {
  const child = Bun.spawn(['sh', join(scripts, script), ...args], {
    env: {
      HOME: home,
      PATH: [stubs, dirname(process.execPath), '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(':'),
      TMPDIR: sandbox,
      STUB_LOG: logFile,
      STUB_KEYCHAIN: keychainFile,
      STUB_TUNNELS: tunnelsFile,
      REAL_CLOUDFLARED: realCloudflared ?? '/nonexistent',
      ...extraEnv,
    },
    stdout: 'pipe',
    stderr: 'pipe',
  });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  return { stdout, stderr, code, calls: readFileSync(logFile, 'utf8').split('\n').filter(Boolean) };
}

const mutating = /tunnel create|tunnel route|tunnel delete|tunnel cleanup|launchctl (bootstrap|bootout|kickstart)|add-generic-password|delete-generic-password/;

test('deploy refuses with exit 78 and changes nothing when the Keychain secrets and login certificate are missing', async () => {
  prepare({ source: 'keychain' });
  const result = await run('deploy-cloudflare.sh');
  expect(result.code).toBe(78);
  expect(result.stderr).toContain("Keychain item 'pocketdesk.cloudflare.turn-key-id' is missing");
  expect(result.stderr).toContain("Keychain item 'pocketdesk.cloudflare.turn-api-token' is missing");
  expect(result.stderr).toContain('cloudflared tunnel login');
  expect(result.stderr).toContain('Nothing was changed');
  expect(result.calls.filter(call => mutating.test(call))).toEqual([]);
  expect(existsSync(join(home, 'Library'))).toBe(false);
});

test('deploy refuses when there is no relay environment file', async () => {
  const result = await run('deploy-cloudflare.sh');
  expect(result.code).toBe(78);
  expect(result.stderr).toContain('relay-env.ts init --host');
});

test('deploy with an environment secret source refuses when the secrets are absent from the file', async () => {
  const prepared = prepare({ source: 'env', cert: true });
  writeFileSync(prepared.envFile, readFileSync(prepared.envFile, 'utf8').replace(/CLOUDFLARE_TURN_KEY_API_TOKEN=.*\n/, ''), { mode: 0o600 });
  const result = await run('deploy-cloudflare.sh', ['--apply']);
  expect(result.code).toBe(78);
  expect(result.stderr).toContain('CLOUDFLARE_TURN_KEY_API_TOKEN is not set');
  expect(result.calls.filter(call => mutating.test(call))).toEqual([]);
});

test.skipIf(!realCloudflared)('dry-run with everything present prints the full plan, validates ingress, and mutates nothing', async () => {
  prepare({ source: 'env', cert: true });
  const result = await run('deploy-cloudflare.sh');
  expect(result.stderr).toBe('');
  expect(result.code).toBe(0);
  expect(result.stdout).toContain('mode: dry-run');
  expect(result.stdout).toContain('[dry-run][ACCOUNT] cloudflared tunnel create pocketdesk-relay');
  expect(result.stdout).toContain('only https://relay.pocketdesk-test.dev/signal is routed');
  expect(result.stdout).toContain('[dry-run][LOCAL] install_app');
  expect(result.stdout).toContain('DNS change: cloudflared tunnel route dns pocketdesk-relay relay.pocketdesk-test.dev');
  expect(result.stdout).toContain('[dry-run][PUBLIC] route_dns');
  expect(result.stdout).toContain('[dry-run][PUBLIC] launchctl bootstrap');
  expect(result.stdout).toContain('dry run complete: no state was changed');
  expect(result.stdout).not.toContain(apiToken);
  expect(result.calls.filter(call => mutating.test(call))).toEqual([]);
  expect(existsSync(join(home, 'Library'))).toBe(false);
  expect(existsSync(join(home, '.pocketdesk', 'relay', 'cloudflared.yml'))).toBe(false);
  expect(existsSync(join(home, '.pocketdesk', 'relay', 'app'))).toBe(false);
  expect(readdirSync(sandbox).filter(name => name.startsWith('pocketdesk-deploy.'))).toEqual([]);
});

test.skipIf(!realCloudflared)('dry-run reuses an existing tunnel instead of planning to create one', async () => {
  prepare({ source: 'env', cert: true });
  writeFileSync(tunnelsFile, JSON.stringify([{ id: '6ff42ae2-765d-4adf-8112-31c55c1551ef', name: 'pocketdesk-relay' }]));
  const result = await run('deploy-cloudflare.sh');
  expect(result.code).toBe(0);
  expect(result.stdout).toContain('tunnel already exists: 6ff42ae2-765d-4adf-8112-31c55c1551ef');
  expect(result.stdout).not.toContain('tunnel create');
  expect(result.stdout).toContain('6ff42ae2-765d-4adf-8112-31c55c1551ef.cfargotunnel.com');
});

test('deploy rejects unknown arguments before doing anything', async () => {
  const result = await run('deploy-cloudflare.sh', ['--publish-now']);
  expect(result.code).toBe(64);
  expect(result.calls).toEqual([]);
});

test('teardown dry-run lists the stop order and the dashboard-only follow-ups without changing anything', async () => {
  prepare({ source: 'keychain', keychainItems: ['pocketdesk.cloudflare.turn-key-id', 'pocketdesk.cloudflare.turn-api-token'], cert: true });
  const agents = join(home, 'Library', 'LaunchAgents');
  mkdirSync(agents, { recursive: true });
  writeFileSync(join(agents, 'com.pocketdesk.relay.tunnel.plist'), 'x');
  writeFileSync(join(agents, 'com.pocketdesk.relay.signal.plist'), 'x');
  const result = await run('teardown-cloudflare.sh', ['--delete-tunnel', '--purge-secrets', '--purge-files'], { STUB_LOADED: '1' });
  expect(result.code).toBe(0);
  const plan = result.stdout;
  expect(plan.indexOf('bootout gui/')).toBeGreaterThan(-1);
  expect(plan.indexOf('com.pocketdesk.relay.tunnel')).toBeLessThan(plan.indexOf('com.pocketdesk.relay.signal', plan.indexOf('com.pocketdesk.relay.tunnel') + 10));
  expect(plan).toContain('[dry-run][ACCOUNT] cloudflared tunnel delete pocketdesk-relay');
  expect(plan).toContain('[dry-run][LOCAL] security delete-generic-password -s pocketdesk.cloudflare.turn-api-token');
  expect(plan).toContain('delete the CNAME');
  expect(plan).toContain('delete the TURN key');
  expect(result.calls.filter(call => mutating.test(call))).toEqual([]);
  expect(existsSync(join(agents, 'com.pocketdesk.relay.tunnel.plist'))).toBe(true);
});

test('rotation dry-run names the idle slot and flips nothing', async () => {
  const prepared = prepare({ source: 'keychain', keychainItems: ['pocketdesk.cloudflare.turn-key-id', 'pocketdesk.cloudflare.turn-api-token'] });
  const before = readFileSync(prepared.envFile, 'utf8');
  const result = await run('rotate-turn-key.sh');
  expect(result.code).toBe(0);
  expect(result.stdout).toContain('active slot: a; the new key goes into slot: b');
  expect(result.stdout).toContain('[dry-run][LOCAL] store_new_key');
  expect(result.stdout).toContain('--slot b');
  expect(result.stdout).toContain('Delete the OLD TURN key');
  expect(readFileSync(prepared.envFile, 'utf8')).toBe(before);
  expect(result.calls.filter(call => mutating.test(call))).toEqual([]);
});

function useReadinessStub() {
  writeStub('lsof', 'exit 1');
  writeStub('bun', `
case "$*" in
  *readiness.ts*--offline*) exec "$REAL_BUN" "$@" ;;
  *readiness.ts*) echo '{"status":"ready","stub":true}'; exit 0 ;;
esac
exec "$REAL_BUN" "$@"`);
}

function serveReady(port: number) {
  return Bun.serve({ hostname: '127.0.0.1', port, fetch: () => new Response('{}', { status: 200 }) });
}

function parsePort(envFile: string) {
  return Number(/^PORT=(\d+)$/m.exec(readFileSync(envFile, 'utf8'))![1]);
}

test.skipIf(!realCloudflared)('apply performs LOCAL and ACCOUNT steps, is idempotent, and stops before PUBLIC without explicit approval', async () => {
  const prepared = prepare({ source: 'env', cert: true });
  useReadinessStub();
  const port = parsePort(prepared.envFile);
  const server = serveReady(port);
  const stubEnv = { REAL_BUN: process.execPath, POCKETDESK_TUNNEL_SETTLE_SECONDS: '0' };
  try {
    const first = await run('deploy-cloudflare.sh', ['--apply'], stubEnv);
    expect(first.stderr).toBe('');
    expect(first.code).toBe(0);
    expect(first.calls.filter(call => /tunnel create pocketdesk-relay/.test(call))).toHaveLength(1);
    expect(first.calls.some(call => /launchctl bootstrap gui\/\d+ .*com\.pocketdesk\.relay\.signal\.plist/.test(call))).toBe(true);
    expect(first.calls.some(call => /tunnel route dns/.test(call))).toBe(false);
    expect(first.calls.some(call => /launchctl bootstrap .*relay\.tunnel\.plist/.test(call))).toBe(false);
    expect(first.stdout).toContain('[blocked][PUBLIC]');
    expect(first.stdout).toContain('PUBLIC steps were skipped; nothing is reachable from the internet');
    expect(first.stdout).not.toContain(apiToken);

    const relayHome = join(home, '.pocketdesk', 'relay');
    const tunnelConfig = readFileSync(join(relayHome, 'cloudflared.yml'), 'utf8');
    expect(tunnelConfig).toContain('tunnel: 6ff42ae2-765d-4adf-8112-31c55c1551ef');
    expect(tunnelConfig).toContain('hostname: relay.pocketdesk-test.dev');
    expect(tunnelConfig).toContain('path: ^/signal$');
    expect(tunnelConfig).toContain(`service: http://127.0.0.1:${port}`);
    expect(statSync(join(relayHome, 'cloudflared.yml')).mode & 0o777).toBe(0o600);
    expect(statSync(join(home, '.cloudflared', '6ff42ae2-765d-4adf-8112-31c55c1551ef.json')).mode & 0o777).toBe(0o600);
    const signalPlist = readFileSync(join(home, 'Library', 'LaunchAgents', 'com.pocketdesk.relay.signal.plist'), 'utf8');
    expect(signalPlist).toContain(`--env-file=${prepared.envFile}`);
    expect(signalPlist).toContain(`${relayHome}/app/src/index.ts`);
    expect(signalPlist).not.toContain('@');
    expect(existsSync(join(relayHome, 'app', 'src', 'server.ts'))).toBe(true);
    expect(existsSync(join(relayHome, 'app', 'src', 'browser'))).toBe(false);

    writeFileSync(logFile, '');
    const second = await run('deploy-cloudflare.sh', ['--apply'], stubEnv);
    expect(second.code).toBe(0);
    expect(second.stdout).toContain('tunnel already exists: 6ff42ae2-765d-4adf-8112-31c55c1551ef');
    expect(second.calls.some(call => /tunnel create/.test(call))).toBe(false);

    writeFileSync(logFile, '');
    const approved = await run('deploy-cloudflare.sh', ['--apply'], { ...stubEnv, POCKETDESK_APPROVE_PUBLIC: 'yes' });
    expect(approved.stderr).toBe('');
    expect(approved.code).toBe(0);
    expect(approved.calls.some(call => /tunnel route dns pocketdesk-relay relay\.pocketdesk-test\.dev/.test(call))).toBe(true);
    expect(approved.calls.some(call => /launchctl bootstrap .*relay\.tunnel\.plist/.test(call))).toBe(true);
    expect(approved.stdout).toContain('wss://relay.pocketdesk-test.dev/signal');
  } finally {
    server.stop(true);
  }
}, 30_000);

test('teardown apply stops the tunnel before the service, removes both plists, and deletes only what it was asked to', async () => {
  const prepared = prepare({ source: 'keychain', keychainItems: ['pocketdesk.cloudflare.turn-key-id', 'pocketdesk.cloudflare.turn-api-token'], cert: true });
  const agents = join(home, 'Library', 'LaunchAgents');
  mkdirSync(agents, { recursive: true });
  writeFileSync(join(agents, 'com.pocketdesk.relay.tunnel.plist'), 'x');
  writeFileSync(join(agents, 'com.pocketdesk.relay.signal.plist'), 'x');
  const plain = await run('teardown-cloudflare.sh', ['--apply'], { STUB_LOADED: '1' });
  expect(plain.code).toBe(0);
  const bootouts = plain.calls.filter(call => call.includes('bootout'));
  expect(bootouts).toHaveLength(2);
  expect(bootouts[0]).toContain('com.pocketdesk.relay.tunnel');
  expect(bootouts[1]).toContain('com.pocketdesk.relay.signal');
  expect(existsSync(join(agents, 'com.pocketdesk.relay.tunnel.plist'))).toBe(false);
  expect(existsSync(join(agents, 'com.pocketdesk.relay.signal.plist'))).toBe(false);
  expect(plain.calls.some(call => /delete-generic-password|tunnel delete/.test(call))).toBe(false);
  expect(existsSync(prepared.envFile)).toBe(true);

  const full = await run('teardown-cloudflare.sh', ['--apply', '--delete-tunnel', '--purge-secrets']);
  expect(full.code).toBe(0);
  expect(full.calls.filter(call => /delete-generic-password -s pocketdesk\.cloudflare\.turn-(key-id|api-token)$/.test(call))).toHaveLength(2);
  expect(full.calls.some(call => /tunnel cleanup pocketdesk-relay/.test(call))).toBe(true);
  expect(full.calls.some(call => /tunnel delete pocketdesk-relay/.test(call))).toBe(true);
  expect(existsSync(prepared.envFile)).toBe(true);
});

test('rotation targets slot a again when slot b is active', async () => {
  const prepared = prepare({ source: 'keychain', keychainItems: [] });
  setEnvValue(prepared.envFile, 'POCKETDESK_KEYCHAIN_SLOT', 'b');
  const result = await run('rotate-turn-key.sh');
  expect(result.code).toBe(0);
  expect(result.stdout).toContain('active slot: b; the new key goes into slot: a');
});
