import { expect, test } from 'bun:test';
import { loadServiceConfig } from '../src/config';
import { keychainServiceName, resolveRelaySecrets, secretSource } from '../src/secrets';

const keyId = 'k'.repeat(32);
const apiToken = 't'.repeat(64);

function keychainReader(items: Record<string, string>) {
  const requested: string[] = [];
  return { requested, reader: async (service: string) => { requested.push(service); return items[service]; } };
}

test('the default slot uses the fixed Keychain service names and the other slot is suffixed', () => {
  expect(keychainServiceName({}, 'turn-key-id')).toBe('pocketdesk.cloudflare.turn-key-id');
  expect(keychainServiceName({}, 'turn-api-token')).toBe('pocketdesk.cloudflare.turn-api-token');
  expect(keychainServiceName({ POCKETDESK_KEYCHAIN_SLOT: 'b' }, 'turn-api-token')).toBe('pocketdesk.cloudflare.turn-api-token.b');
  expect(keychainServiceName({ POCKETDESK_KEYCHAIN_PREFIX: 'test.prefix' }, 'turn-key-id')).toBe('test.prefix.turn-key-id');
});

test('an environment secret source returns the very same environment without touching the Keychain', async () => {
  const { reader, requested } = keychainReader({});
  const env = { NODE_ENV: 'production', CLOUDFLARE_TURN_KEY_ID: keyId };
  expect(await resolveRelaySecrets(env, { reader })).toBe(env);
  expect(requested).toEqual([]);
});

test('the Keychain source reads both fixed items by service name and fills the Cloudflare variables', async () => {
  const { reader, requested } = keychainReader({
    'pocketdesk.cloudflare.turn-key-id': keyId,
    'pocketdesk.cloudflare.turn-api-token': apiToken,
  });
  const env = { POCKETDESK_SECRET_SOURCE: 'keychain', TURN_PROVIDER: 'cloudflare', NODE_ENV: 'production', ALLOWED_ROOMS: 'f'.repeat(64) };
  const resolved = await resolveRelaySecrets(env, { reader });
  expect(requested).toEqual(['pocketdesk.cloudflare.turn-key-id', 'pocketdesk.cloudflare.turn-api-token']);
  expect(resolved.CLOUDFLARE_TURN_KEY_ID).toBe(keyId);
  expect(resolved.CLOUDFLARE_TURN_KEY_API_TOKEN).toBe(apiToken);
  expect(env).not.toHaveProperty('CLOUDFLARE_TURN_KEY_API_TOKEN');
  expect(loadServiceConfig(resolved).turnProvider?.kind).toBe('cloudflare');
});

test('the Keychain source refuses a token that is also present in the environment file', async () => {
  const { reader } = keychainReader({
    'pocketdesk.cloudflare.turn-key-id': keyId,
    'pocketdesk.cloudflare.turn-api-token': apiToken,
  });
  await expect(resolveRelaySecrets({ POCKETDESK_SECRET_SOURCE: 'keychain', CLOUDFLARE_TURN_KEY_API_TOKEN: apiToken }, { reader }))
    .rejects.toThrow('must not be set when POCKETDESK_SECRET_SOURCE=keychain');
});

test('a missing or empty Keychain item fails naming the service and never a value', async () => {
  const { reader } = keychainReader({ 'pocketdesk.cloudflare.turn-key-id': keyId, 'pocketdesk.cloudflare.turn-api-token': '' });
  const failure = await resolveRelaySecrets({ POCKETDESK_SECRET_SOURCE: 'keychain' }, { reader }).catch(error => error as Error);
  expect(failure.message).toBe('Keychain item pocketdesk.cloudflare.turn-api-token is missing or empty');
  expect(failure.message).not.toContain(keyId);
  const absent = await resolveRelaySecrets({ POCKETDESK_SECRET_SOURCE: 'keychain' }, { reader: keychainReader({}).reader }).catch(error => error as Error);
  expect(absent.message).toContain('pocketdesk.cloudflare.turn-key-id');
});

test('invalid source, slot and prefix values are rejected before any lookup', async () => {
  const { reader, requested } = keychainReader({});
  expect(() => secretSource({ POCKETDESK_SECRET_SOURCE: 'file' })).toThrow('must be env or keychain');
  await expect(resolveRelaySecrets({ POCKETDESK_SECRET_SOURCE: 'keychain', POCKETDESK_KEYCHAIN_SLOT: 'A/../b' }, { reader })).rejects.toThrow('POCKETDESK_KEYCHAIN_SLOT');
  await expect(resolveRelaySecrets({ POCKETDESK_SECRET_SOURCE: 'keychain', POCKETDESK_KEYCHAIN_PREFIX: 'bad prefix' }, { reader })).rejects.toThrow('POCKETDESK_KEYCHAIN_PREFIX');
  expect(requested).toEqual([]);
});
