export type SecretEnvironment = Record<string, string | undefined>;
export type KeychainReader = (service: string) => Promise<string | undefined>;
export type KeychainPresence = (service: string) => Promise<boolean>;

export const DEFAULT_KEYCHAIN_PREFIX = 'pocketdesk.cloudflare';
export const DEFAULT_KEYCHAIN_SLOT = 'a';
export const RELAY_SECRETS = [
  { env: 'CLOUDFLARE_TURN_KEY_ID', item: 'turn-key-id' },
  { env: 'CLOUDFLARE_TURN_KEY_API_TOKEN', item: 'turn-api-token' },
] as const;

const prefixPattern = /^[A-Za-z0-9._-]{1,64}$/;
const slotPattern = /^[a-z0-9]{1,8}$/;
const securityBinary = '/usr/bin/security';
const keychainTimeoutMs = 5000;

export function secretSource(env: SecretEnvironment): 'env' | 'keychain' {
  const source = env.POCKETDESK_SECRET_SOURCE ?? 'env';
  if (source !== 'env' && source !== 'keychain') throw new Error('POCKETDESK_SECRET_SOURCE must be env or keychain');
  return source;
}

export function keychainSlot(env: SecretEnvironment): string {
  const slot = env.POCKETDESK_KEYCHAIN_SLOT ?? DEFAULT_KEYCHAIN_SLOT;
  if (!slotPattern.test(slot)) throw new Error('POCKETDESK_KEYCHAIN_SLOT must be 1-8 lowercase letters or digits');
  return slot;
}

export function keychainServiceName(env: SecretEnvironment, item: string): string {
  const prefix = env.POCKETDESK_KEYCHAIN_PREFIX ?? DEFAULT_KEYCHAIN_PREFIX;
  if (!prefixPattern.test(prefix)) throw new Error('POCKETDESK_KEYCHAIN_PREFIX is invalid');
  const slot = keychainSlot(env);
  return slot === DEFAULT_KEYCHAIN_SLOT ? `${prefix}.${item}` : `${prefix}.${item}.${slot}`;
}

async function runSecurity(args: string[], captureOutput: boolean) {
  if (process.platform !== 'darwin') throw new Error('the keychain secret source requires macOS');
  const child = Bun.spawn([securityBinary, ...args], {
    stdin: 'ignore',
    stdout: captureOutput ? 'pipe' : 'ignore',
    stderr: 'ignore',
    timeout: keychainTimeoutMs,
  });
  const output = captureOutput ? await new Response(child.stdout as ReadableStream).text() : '';
  const status = await child.exited;
  return { status, output };
}

export const readKeychainPassword: KeychainReader = async service => {
  const { status, output } = await runSecurity(['find-generic-password', '-s', service, '-w'], true);
  if (status === 44) return undefined;
  if (status !== 0) throw new Error(`keychain read failed for ${service} (status ${status})`);
  return output.replace(/\r?\n$/, '');
};

export const keychainItemPresent: KeychainPresence = async service => {
  const { status } = await runSecurity(['find-generic-password', '-s', service], false);
  if (status === 0) return true;
  if (status === 44) return false;
  throw new Error(`keychain lookup failed for ${service} (status ${status})`);
};

export async function resolveRelaySecrets(
  env: SecretEnvironment,
  options: { reader?: KeychainReader } = {},
): Promise<SecretEnvironment> {
  if (secretSource(env) === 'env') return env;
  const reader = options.reader ?? readKeychainPassword;
  const resolved: SecretEnvironment = { ...env };
  for (const secret of RELAY_SECRETS) {
    if (env[secret.env]) {
      throw new Error(`${secret.env} must not be set when POCKETDESK_SECRET_SOURCE=keychain; remove it from the environment file`);
    }
    const service = keychainServiceName(env, secret.item);
    const value = await reader(service);
    if (!value) throw new Error(`Keychain item ${service} is missing or empty`);
    resolved[secret.env] = value;
  }
  return resolved;
}
