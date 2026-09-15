import { describe, expect, test } from 'bun:test';
import { createPacket, releasePacket, validDecimal, validateAction } from '../src/control/input.js';
describe('browser control packet validation', () => {
  const session = 'b'.repeat(64);
  test('accepts a bounded relative move with a current token', () => expect(createPacket({ session, sequence: '1', revision: '2', frameToken: 'a'.repeat(32), action: { action: 'move', x: 4, y: -3, epoch: 2 } }).action.action).toBe('move'));
  test('normalizes symbolic keys while preserving their modifiers', () => {
    const commandA = createPacket({ session, sequence: '2', revision: '2', frameToken: 'a'.repeat(32), action: { action: 'key', key: ' A ', modifiers: ['command'], epoch: 2 } }).action;
    const shiftedReturn = createPacket({ session, sequence: '3', revision: '2', frameToken: 'a'.repeat(32), action: { action: 'key', key: ' Return ', modifiers: ['shift'], epoch: 2 } }).action;
    expect(commandA.key).toBe('a');
    expect(commandA.modifiers).toEqual(['command']);
    expect(shiftedReturn.key).toBe('return');
    expect(shiftedReturn.modifiers).toEqual(['shift']);
  });
  test('preserves committed text and its receipt key exactly', () => {
    const text = '  Let APIKey = "MixedCase";\n';
    const requestKey = 'Request-ID-A1';
    const action = createPacket({ session, sequence: '4', revision: '2', frameToken: 'a'.repeat(32), action: { action: 'text', text, key: requestKey, epoch: 2 } }).action;
    expect(action.text).toBe(text);
    expect(action.key).toBe(requestKey);
  });
  test('rejects malformed sequence, token and action bounds', () => { expect(validDecimal('01')).toBe(false); expect(() => createPacket({ session, sequence: 'x', revision: '2', frameToken: 'a'.repeat(32), action: { action: 'click' } })).toThrow(); expect(validateAction({ action: 'move', x: 20001 })).toBe(false); expect(validateAction({ action: 'key', modifiers: ['invalid'] })).toBe(false); });
  test('makes a scoped release packet without freshness input', () => expect(releasePacket({ session, sequence: '3', revision: '2' }).action.action).toBe('release'));
});
