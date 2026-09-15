import { test, expect } from 'bun:test';
import { canonical, hash, generateIdentity, generateEphemeral, sign, verify, sharedKey, seal, open, sealEnrollment } from '../src/crypto.js';

test('enrollment is opaque to relay and authenticates key host and origin', async () => {
  const identity = await generateIdentity(), offer = {secret:'3'.repeat(64),hostID:'4'.repeat(64),url:'http://127.0.0.1:8791'};
  const packet = await sealEnrollment(offer,'5'.repeat(64),identity.publicKey);
  expect(Object.keys(packet).sort()).toEqual(['nonce','payload']);
  expect(JSON.stringify(packet)).not.toContain(offer.secret);
  expect(JSON.stringify(packet)).not.toContain(identity.publicKey);
  const key = await crypto.subtle.importKey('raw',new Uint8Array(32).fill(0x33),'AES-GCM',false,['decrypt']);
  const parameters = {name:'AES-GCM',iv:Buffer.from(packet.nonce,'base64'),additionalData:canonical(['enroll',offer.hostID,offer.url])};
  const decoded = JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt(parameters,key,Buffer.from(packet.payload,'base64'))));
  expect(decoded).toEqual({peerID:'5'.repeat(64),publicKey:identity.publicKey});
  await expect(crypto.subtle.decrypt({...parameters,additionalData:canonical(['enroll',offer.hostID,'https://wrong.invalid'])},key,Buffer.from(packet.payload,'base64'))).rejects.toThrow();
});

test('P1363 signatures bind field lengths/order and reject malformed keys', async () => {
  const key = await generateIdentity();
  expect(key.privateKey.extractable).toBe(false);
  const sig = await sign(['challenge', 'ab', 'c', '中文'], key.privateKey);
  expect(await verify(['challenge', 'ab', 'c', '中文'], sig, key.publicKey)).toBe(true);
  expect(await verify(['challenge', 'a', 'bc', '中文'], sig, key.publicKey)).toBe(false);
  expect(await verify(['challenge', 'ab', 'c', '中文'], sig + '=', key.publicKey)).toBe(false);
  expect(await verify(['challenge'], sig, 'invalid')).toBe(false);
});
test('ECDH WebCrypto encrypted signals bind direction session transcript and sequence', async () => {
  const host = await generateEphemeral(), browser = await generateEphemeral();
  const fields = ['challenge', 'fixture'];
  const h = await sharedKey(host.privateKey, browser.publicKey, fields), b = await sharedKey(browser.privateKey, host.publicKey, fields);
  const session = '1'.repeat(64), ch = await hash(canonical(fields));
  const envelope = await seal({ kind: 'ready' }, b, session, 'browser', 1, ch);
  expect(await open(envelope, h, session, 'browser', ch)).toEqual({ kind: 'ready' });
  for (const args of [ [session, 'host', ch], ['2'.repeat(64), 'browser', ch], [session, 'browser', '0'.repeat(64)] ]) {
    await expect(open(envelope, h, ...args)).rejects.toThrow();
  }
  await expect(open({ ...envelope, sequence: '2' }, h, session, 'browser', ch)).rejects.toThrow();
  await expect(seal({}, b, session, 'browser', 0, ch)).rejects.toThrow();
});
test('fixed cross-language signature and ciphertext fixture', async () => {
  const v = await Bun.file(new URL('../../BrowserFixtures/crypto-vector.json', import.meta.url)).json();
  expect(await hash(canonical(v.fields))).toBe(v.hash);
  expect(await verify(v.fields, v.signature, v.signingPublic)).toBe(true);
  const privateKey = await crypto.subtle.importKey('jwk', v.browserJWK, {name:'ECDH',namedCurve:'P-256'}, false, ['deriveBits']);
  const key = await sharedKey(privateKey, v.hostPublic, v.fields);
  expect(await open(v.envelope, key, v.session, 'host', v.hash)).toEqual({kind:'ready'});
});
