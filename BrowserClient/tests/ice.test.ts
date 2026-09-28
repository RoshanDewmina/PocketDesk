import { describe, expect, test } from 'bun:test';
import { buildRTCConfiguration, validateIceMessage } from '../src/viewer/ice.js';

describe('browser ice message validation', () => {
  test('accepts stun-only servers under policy all', () => {
    const message = { type: 'ice', servers: [{ urls: ['stun:stun.example:3478'] }], policy: 'all' };
    expect(validateIceMessage(message)).toEqual({ servers: message.servers, policy: 'all' });
  });
  test('accepts an empty server list under policy all', () => {
    expect(validateIceMessage({ type: 'ice', servers: [], policy: 'all' })).toEqual({ servers: [], policy: 'all' });
  });
  test('accepts turn servers with credentials under policy relay', () => {
    const message = { type: 'ice', servers: [{ urls: ['turn:turn.example:3478'], username: 'u', credential: 'c' }], policy: 'relay' };
    expect(validateIceMessage(message)).toEqual({ servers: message.servers, policy: 'relay' });
  });
  test('accepts turns scheme for relay policy', () => {
    const message = { type: 'ice', servers: [{ urls: ['turns:turn.example:5349'] }], policy: 'relay' };
    expect(validateIceMessage(message).policy).toBe('relay');
  });
  test('rejects relay policy with only stun servers', () => {
    const message = { type: 'ice', servers: [{ urls: ['stun:stun.example:3478'] }], policy: 'relay' };
    expect(() => validateIceMessage(message)).toThrow('relay_required_unavailable');
  });
  test('rejects relay policy with no servers at all', () => {
    expect(() => validateIceMessage({ type: 'ice', servers: [], policy: 'relay' })).toThrow('relay_required_unavailable');
  });
  test('rejects more than eight servers', () => {
    const servers = Array.from({ length: 9 }, () => ({ urls: ['stun:stun.example:3478'] }));
    expect(() => validateIceMessage({ type: 'ice', servers, policy: 'all' })).toThrow();
  });
  test('rejects a server with more than eight urls', () => {
    const urls = Array.from({ length: 9 }, (_, index) => `stun:stun${index}.example:3478`);
    expect(() => validateIceMessage({ type: 'ice', servers: [{ urls }], policy: 'all' })).toThrow();
  });
  test('rejects a disallowed url scheme', () => {
    const message = { type: 'ice', servers: [{ urls: ['https://evil.example'] }], policy: 'all' };
    expect(() => validateIceMessage(message)).toThrow();
  });
  test('rejects an unknown policy value', () => {
    expect(() => validateIceMessage({ type: 'ice', servers: [], policy: 'direct' })).toThrow();
  });
  test('rejects an unexpected extra field', () => {
    expect(() => validateIceMessage({ type: 'ice', servers: [], policy: 'all', session: 'a'.repeat(64) })).toThrow();
  });
  test('rejects a wrong message type', () => {
    expect(() => validateIceMessage({ type: 'signal', servers: [], policy: 'all' })).toThrow();
  });
  test('rejects a server object carrying unexpected keys', () => {
    const message = { type: 'ice', servers: [{ urls: ['stun:stun.example:3478'], extra: true }], policy: 'all' };
    expect(() => validateIceMessage(message)).toThrow();
  });
  test('builds an RTCConfiguration preserving credentials and policy', () => {
    const validated = { servers: [{ urls: ['turn:turn.example:3478'], username: 'u', credential: 'c' }, { urls: ['stun:stun.example:3478'] }], policy: 'relay' };
    expect(buildRTCConfiguration(validated)).toEqual({
      iceServers: [{ urls: ['turn:turn.example:3478'], username: 'u', credential: 'c' }, { urls: ['stun:stun.example:3478'] }],
      iceTransportPolicy: 'relay'
    });
  });
});
