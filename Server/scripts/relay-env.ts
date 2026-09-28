#!/usr/bin/env bun
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { isAbsolute, join, resolve } from 'node:path';
import { publicHostCheck } from '../src/relay-config';
import { DEFAULT_KEYCHAIN_SLOT, keychainServiceName, keychainSlot } from '../src/secrets';
import { parsePrivateEnvFile } from './readiness';

const keyPattern = /^[A-Z][A-Z0-9_]*$/;
const valuePattern = /^[A-Za-z0-9._:/@+-]{0,256}$/;
const templatePath = resolve(import.meta.dir, '..', '.env.relay.example');

export function relayHome(env: Record<string, string | undefined> = process.env) {
  const home = env.POCKETDESK_HOME ?? join(env.HOME ?? homedir(), '.pocketdesk', 'relay');
  if (!isAbsolute(home)) throw new Error('POCKETDESK_HOME must be an absolute path');
  return home;
}

export function renderEnvTemplate(template: string, values: { home: string; userHome: string; host?: string; tunnelName?: string }) {
  let text = template.replaceAll('@RELAY_HOME@', values.home).replaceAll('@HOME@', values.userHome);
  text = text.replaceAll('@TUNNEL_NAME@', values.tunnelName ?? 'pocketdesk-relay');
  text = values.host
    ? text.replaceAll('@PD_PUBLIC_HOST_LINE@', `PD_PUBLIC_HOST=${values.host}`)
    : text.replaceAll('@PD_PUBLIC_HOST_LINE@', '# PD_PUBLIC_HOST=relay.your-domain.example');
  if (text.includes('@')) throw new Error('unresolved template placeholder');
  return text;
}

export function setEnvValue(path: string, key: string, value: string) {
  if (!keyPattern.test(key)) throw new Error('invalid key');
  if (!valuePattern.test(value)) throw new Error('invalid value');
  parsePrivateEnvFile(path);
  const lines = readFileSync(path, 'utf8').split(/\r?\n/);
  const assignment = `${key}=${value}`;
  let replaced = false;
  const next = lines.map(line => {
    if (line.startsWith(`${key}=`)) { replaced = true; return assignment; }
    return line;
  });
  if (!replaced) {
    while (next.length && next[next.length - 1] === '') next.pop();
    next.push(assignment, '');
  }
  const temporary = `${path}.tmp.${process.pid}`;
  writeFileSync(temporary, next.join('\n'), { mode: 0o600 });
  chmodSync(temporary, 0o600);
  renameSync(temporary, path);
}

export function tunnelIdFromJson(json: string, name: string): string | undefined {
  const parsed = JSON.parse(json) as unknown;
  if (!Array.isArray(parsed)) throw new Error('unexpected tunnel list output');
  const active = (item: Record<string, unknown>) => {
    const deleted = item.deleted_at;
    return deleted === undefined || deleted === null || deleted === '' || (typeof deleted === 'string' && deleted.startsWith('0001-01-01'));
  };
  const match = parsed.find(item => item && typeof item === 'object' && (item as Record<string, unknown>).name === name &&
    active(item as Record<string, unknown>)) as Record<string, unknown> | undefined;
  return typeof match?.id === 'string' ? match.id : undefined;
}

export function initRelayHome(options: { host?: string; tunnelName?: string; force?: boolean; env?: Record<string, string | undefined> }) {
  const env = options.env ?? process.env;
  const home = relayHome(env);
  if (options.host) {
    const check = publicHostCheck(options.host);
    if (check.level === 'fail') throw new Error(check.detail);
  }
  mkdirSync(home, { recursive: true, mode: 0o700 });
  chmodSync(home, 0o700);
  const envFile = join(home, 'relay.env');
  if (existsSync(envFile) && !options.force) throw new Error(`${envFile} already exists; pass --force to replace it`);
  const text = renderEnvTemplate(readFileSync(templatePath, 'utf8'), {
    home,
    userHome: env.HOME ?? homedir(),
    host: options.host,
    tunnelName: options.tunnelName,
  });
  writeFileSync(envFile, text, { mode: 0o600 });
  chmodSync(envFile, 0o600);
  const approved = join(home, 'approved-rooms');
  if (!existsSync(approved)) writeFileSync(approved, '', { mode: 0o600 });
  chmodSync(approved, 0o600);
  parsePrivateEnvFile(envFile);
  return { home, envFile, approved };
}

function option(name: string) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

async function readStdin() {
  return await new Response(Bun.stdin.stream()).text();
}

async function main() {
  const [command, first, second] = process.argv.slice(2);
  if (command === 'get' && first) {
    const path = option('--env-file') ?? join(relayHome(), 'relay.env');
    const value = parsePrivateEnvFile(path)[first];
    if (value === undefined) process.exit(1);
    console.log(value);
  } else if (command === 'set' && first && second !== undefined) {
    setEnvValue(option('--env-file') ?? join(relayHome(), 'relay.env'), first, second);
  } else if (command === 'tunnel-id' && first) {
    const id = tunnelIdFromJson(await readStdin(), first);
    if (!id) process.exit(1);
    console.log(id);
  } else if (command === 'keychain-service' && first) {
    const env = parsePrivateEnvFile(option('--env-file') ?? join(relayHome(), 'relay.env'));
    const slot = option('--slot');
    if (slot) env.POCKETDESK_KEYCHAIN_SLOT = slot;
    console.log(keychainServiceName(env, first));
  } else if (command === 'other-slot') {
    const env = parsePrivateEnvFile(option('--env-file') ?? join(relayHome(), 'relay.env'));
    console.log(keychainSlot(env) === DEFAULT_KEYCHAIN_SLOT ? 'b' : DEFAULT_KEYCHAIN_SLOT);
  } else if (command === 'init') {
    const result = initRelayHome({ host: option('--host'), tunnelName: option('--tunnel-name'), force: process.argv.includes('--force') });
    console.log(JSON.stringify({ status: 'initialized', envFile: result.envFile, approvedRooms: result.approved }, null, 2));
  } else {
    throw new Error('usage: relay-env.ts get KEY | set KEY VALUE | tunnel-id NAME | keychain-service ITEM [--slot S] | other-slot | init [--host HOST] [--tunnel-name NAME] [--force]');
  }
}

if (import.meta.main) {
  main().catch(error => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
