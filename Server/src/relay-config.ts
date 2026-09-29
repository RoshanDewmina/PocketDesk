import { lstatSync, readFileSync, statSync } from 'node:fs';
import { dirname, isAbsolute, relative, resolve } from 'node:path';
import { loadServiceConfig } from './config';
import {
  RELAY_SECRETS,
  keychainItemPresent,
  keychainServiceName,
  secretSource,
  type KeychainPresence,
  type SecretEnvironment,
} from './secrets';

export type CheckLevel = 'pass' | 'warn' | 'fail';
export type Check = { id: string; level: CheckLevel; detail: string };
export type PreflightReport = { ok: boolean; checks: Check[] };

export type PreflightOptions = {
  repoRoot?: string;
  cloudflaredConfigPath?: string;
  keychainPresent?: KeychainPresence;
  resolvedEnv?: SecretEnvironment;
  resolveError?: string;
  fetch?: typeof globalThis.fetch;
};

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const loopbackHosts = new Set(['127.0.0.1', '::1', '[::1]', 'localhost']);
const publicProbePaths = ['/', '/health', '/ready', '/signal/extra', '/browser-host', '/browser-signal', '/api/diagnostics', '/probe/x', '/fixtures/x'];

const pass = (id: string, detail: string): Check => ({ id, level: 'pass', detail });
const warn = (id: string, detail: string): Check => ({ id, level: 'warn', detail });
const fail = (id: string, detail: string): Check => ({ id, level: 'fail', detail });

function numberFrom(env: SecretEnvironment, name: string, fallback: number) {
  const raw = env[name];
  return raw === undefined ? fallback : Number(raw);
}

function privateFileCheck(id: string, label: string, path: string | undefined, required: boolean): Check {
  if (!path) return required ? fail(id, `${label} is not configured`) : warn(id, `${label} is not configured`);
  if (!isAbsolute(path)) return fail(id, `${label} must be an absolute path`);
  let stat;
  try { stat = lstatSync(path); } catch { return fail(id, `${label} does not exist`); }
  if (!stat.isFile() || stat.isSymbolicLink()) return fail(id, `${label} must be a regular file`);
  if ((stat.mode & 0o077) !== 0) return fail(id, `${label} must be mode 600 (no group or other access)`);
  return pass(id, `${label} exists with private permissions`);
}

function outsideRepo(id: string, label: string, path: string | undefined, repoRoot: string | undefined): Check | undefined {
  if (!path || !repoRoot || !isAbsolute(path)) return undefined;
  const relation = relative(resolve(repoRoot), resolve(path));
  if (relation === '' || (!relation.startsWith('..') && !isAbsolute(relation))) return fail(id, `${label} must be outside the repository`);
  return undefined;
}

const hostnamePattern = /^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;

export function publicHostCheck(host: string | undefined): Check {
  if (!host) return warn('public_host', 'PD_PUBLIC_HOST is not set; the named-tunnel deploy needs it');
  if (!hostnamePattern.test(host)) return fail('public_host', 'PD_PUBLIC_HOST must be a lowercase DNS hostname without scheme, path or port');
  if (host === 'example.com' || host.endsWith('.example.com')) return fail('public_host', 'PD_PUBLIC_HOST is still the example.com placeholder');
  if (host.endsWith('.trycloudflare.com')) return warn('public_host', 'a trycloudflare.com host is a temporary Quick Tunnel hostname');
  if (host.split('.').length > 3) return warn('public_host', 'a hostname deeper than first level under your domain is not covered by Cloudflare Universal SSL');
  return pass('public_host', `public signaling URL will be wss://${host}/signal`);
}

export function checkCloudflaredConfig(path: string, hostname: string | undefined, servicePort: number): Check[] {
  const checks: Check[] = [];
  let stat;
  try { stat = lstatSync(path); } catch { return [fail('cloudflared_config', 'cloudflared config file does not exist')]; }
  if (!stat.isFile() || stat.isSymbolicLink()) return [fail('cloudflared_config', 'cloudflared config must be a regular file')];
  if ((stat.mode & 0o022) !== 0) checks.push(fail('cloudflared_config_permissions', 'cloudflared config must not be group or other writable'));

  let parsed: unknown;
  try { parsed = Bun.YAML.parse(readFileSync(path, 'utf8')); } catch { return [...checks, fail('cloudflared_config', 'cloudflared config is not valid YAML')]; }
  if (!parsed || typeof parsed !== 'object') return [...checks, fail('cloudflared_config', 'cloudflared config is empty')];
  const config = parsed as Record<string, unknown>;

  if (typeof config.tunnel !== 'string' || !uuid.test(config.tunnel)) checks.push(fail('tunnel_id', 'tunnel must be the tunnel UUID'));
  else checks.push(pass('tunnel_id', 'tunnel UUID is well formed'));

  const credentials = config['credentials-file'];
  if (typeof credentials !== 'string') checks.push(fail('tunnel_credentials', 'credentials-file is not configured'));
  else checks.push(privateFileCheck('tunnel_credentials', 'tunnel credentials file', credentials, true));

  if (config['warp-routing'] !== undefined) checks.push(fail('warp_routing', 'warp-routing must not be enabled for the relay tunnel'));

  const ingress = config.ingress;
  if (!Array.isArray(ingress) || ingress.length < 2) return [...checks, fail('ingress', 'ingress needs a signal rule and a catch-all 404 rule')];
  const rules = ingress as Record<string, unknown>[];
  const catchAll = rules[rules.length - 1];
  if (catchAll.hostname !== undefined || catchAll.path !== undefined || catchAll.service !== 'http_status:404') {
    checks.push(fail('ingress_catch_all', 'the last ingress rule must be exactly service: http_status:404'));
  } else checks.push(pass('ingress_catch_all', 'catch-all rule answers 404'));

  const routed = rules.slice(0, -1);
  if (routed.length !== 1) return [...checks, fail('ingress_rules', 'exactly one routed ingress rule (the signal path) is allowed')];
  const rule = routed[0];
  if (typeof rule.hostname !== 'string' || (hostname !== undefined && rule.hostname !== hostname)) {
    checks.push(fail('ingress_hostname', 'ingress hostname must match PD_PUBLIC_HOST'));
  } else checks.push(pass('ingress_hostname', 'ingress hostname matches PD_PUBLIC_HOST'));

  let origin: URL | undefined;
  try { origin = new URL(String(rule.service)); } catch { /* reported below */ }
  if (!origin || origin.protocol !== 'http:' || !loopbackHosts.has(origin.hostname) || Number(origin.port) !== servicePort) {
    checks.push(fail('ingress_origin', `origin must be plain http on loopback port ${servicePort}`));
  } else checks.push(pass('ingress_origin', 'origin is the loopback signaling port'));

  if (typeof rule.path !== 'string') checks.push(fail('ingress_path', 'the signal rule must restrict the public path'));
  else {
    let matcher: RegExp | undefined;
    try { matcher = new RegExp(rule.path); } catch { /* reported below */ }
    if (!matcher) checks.push(fail('ingress_path', 'ingress path is not a valid regular expression'));
    else if (!matcher.test('/signal')) checks.push(fail('ingress_path', 'ingress path does not match /signal'));
    else {
      const leaked = publicProbePaths.filter(candidate => matcher!.test(candidate));
      if (leaked.length) checks.push(fail('ingress_path', `ingress path also exposes ${leaked.join(', ')}`));
      else checks.push(pass('ingress_path', 'only /signal is publicly routed; health, readiness and browser paths are not'));
    }
  }
  return checks;
}

export async function preflightRelay(env: SecretEnvironment, options: PreflightOptions = {}): Promise<PreflightReport> {
  const checks: Check[] = [];
  const presence = options.keychainPresent ?? keychainItemPresent;

  checks.push(env.NODE_ENV === 'production' ? pass('node_env', 'NODE_ENV=production') : fail('node_env', 'NODE_ENV must be production'));
  if (env.TURN_PROVIDER === 'cloudflare') checks.push(pass('turn_provider', 'TURN_PROVIDER=cloudflare'));
  else if (env.TURN_PROVIDER === 'coturn') checks.push(warn('turn_provider', 'TURN_PROVIDER=coturn; this preflight is tuned for the Cloudflare relay'));
  else checks.push(fail('turn_provider', 'TURN_PROVIDER must be cloudflare'));

  const bind = env.BIND ?? '127.0.0.1';
  checks.push(loopbackHosts.has(bind) ? pass('bind', `service binds loopback (${bind})`) : fail('bind', 'BIND must be loopback; only the tunnel may reach the service'));

  let source: 'env' | 'keychain' | undefined;
  try { source = secretSource(env); } catch (error) { checks.push(fail('secret_source', (error as Error).message)); }
  if (source === 'keychain' && env.TURN_PROVIDER !== 'coturn') {
    for (const secret of RELAY_SECRETS) {
      let service: string;
      try { service = keychainServiceName(env, secret.item); } catch (error) { checks.push(fail(`keychain_${secret.item}`, (error as Error).message)); continue; }
      if (env[secret.env]) checks.push(fail(`keychain_${secret.item}`, `${secret.env} must not also be present in the environment file`));
      else {
        try {
          checks.push(await presence(service)
            ? pass(`keychain_${secret.item}`, `Keychain item ${service} is present`)
            : fail(`keychain_${secret.item}`, `Keychain item ${service} is missing`));
        } catch (error) { checks.push(fail(`keychain_${secret.item}`, (error as Error).message)); }
      }
    }
  } else if (source === 'env' && env.TURN_PROVIDER === 'cloudflare') {
    checks.push(warn('secret_source', 'secrets come from the environment file; prefer POCKETDESK_SECRET_SOURCE=keychain'));
  }
  if (options.resolveError) checks.push(fail('secret_resolution', options.resolveError));

  const ttl = numberFrom(env, 'TURN_CREDENTIAL_TTL_SECONDS', 3600);
  const room = numberFrom(env, 'ROOM_LIFETIME_SECONDS', 1800);
  if (ttl > 86_400 / 4) checks.push(warn('credential_ttl', `credential TTL of ${ttl}s is long; revocation on disconnect is the primary cleanup`));
  else checks.push(pass('credential_ttl', `credential TTL ${ttl}s`));
  checks.push(room < ttl ? pass('room_lifetime', `room lease ${room}s is below the credential TTL; apps that do not renew end here`) : fail('room_lifetime', 'ROOM_LIFETIME_SECONDS must be lower than TURN_CREDENTIAL_TTL_SECONDS'));
  const renewal = env.SESSION_RENEWAL;
  checks.push(renewal === '0' || renewal === 'false'
    ? warn('session_renewal', 'SESSION_RENEWAL is off: every session ends when its room lease does')
    : pass('session_renewal', 'session renewal is on: apps that support it renew the lease and relay credentials while connected'));

  const peers = numberFrom(env, 'MAX_PEERS', 256);
  checks.push(peers <= 16 ? pass('max_peers', `MAX_PEERS=${peers}`) : warn('max_peers', `MAX_PEERS=${peers} is high for a single-owner relay`));
  const issues = numberFrom(env, 'TURN_CREDENTIAL_ISSUES_PER_MINUTE', 12);
  checks.push(issues <= 12 ? pass('issue_rate', `credential issuance limit ${issues}/minute`) : warn('issue_rate', `credential issuance limit ${issues}/minute is high for a single-owner relay`));

  if (env.APPROVED_ROOMS_FILE) checks.push(privateFileCheck('approved_rooms', 'approved rooms file', env.APPROVED_ROOMS_FILE, true));
  else if (env.ALLOWED_ROOMS) checks.push(warn('approved_rooms', 'a static ALLOWED_ROOMS list cannot be revoked without a restart; prefer APPROVED_ROOMS_FILE'));
  else checks.push(fail('approved_rooms', 'APPROVED_ROOMS_FILE (or ALLOWED_ROOMS) is required'));
  const repoCheck = outsideRepo('approved_rooms_location', 'approved rooms file', env.APPROVED_ROOMS_FILE, options.repoRoot);
  if (repoCheck) checks.push(repoCheck);
  if (env.PENDING_ROOMS_FILE) {
    if (!isAbsolute(env.PENDING_ROOMS_FILE)) checks.push(fail('pending_rooms', 'pending rooms file must be an absolute path'));
    else {
      try {
        const directory = statSync(dirname(env.PENDING_ROOMS_FILE));
        checks.push((directory.mode & 0o022) === 0 ? pass('pending_rooms', 'pending rooms directory is not group or other writable') : fail('pending_rooms', 'pending rooms directory must not be group or other writable'));
      } catch { checks.push(fail('pending_rooms', 'pending rooms directory does not exist')); }
    }
    const pendingRepo = outsideRepo('pending_rooms_location', 'pending rooms file', env.PENDING_ROOMS_FILE, options.repoRoot);
    if (pendingRepo) checks.push(pendingRepo);
  }

  const forced = env.POCKETDESK_TEST_FORCE_RELAY;
  if (forced === '1' || forced === 'true') checks.push(warn('force_relay', 'test mode: every session is relay-only; turn off after the acceptance test'));
  else checks.push(pass('force_relay', 'forced-relay test mode is off'));

  checks.push(publicHostCheck(env.PD_PUBLIC_HOST));

  if (options.resolvedEnv) {
    try {
      const loaded = loadServiceConfig(options.resolvedEnv, { fetch: options.fetch });
      checks.push(loaded.turnProvider?.kind === 'cloudflare'
        ? pass('service_config', 'the service configuration loads with a Cloudflare TURN provider')
        : fail('service_config', 'the service configuration loaded without a Cloudflare TURN provider'));
    } catch (error) { checks.push(fail('service_config', (error as Error).message)); }
  }

  if (options.cloudflaredConfigPath) {
    checks.push(...checkCloudflaredConfig(options.cloudflaredConfigPath, env.PD_PUBLIC_HOST, numberFrom(env, 'PORT', 8787)));
  }

  return { ok: checks.every(check => check.level !== 'fail'), checks };
}
