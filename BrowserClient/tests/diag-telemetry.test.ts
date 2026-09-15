import { describe, expect, test } from 'bun:test';
import { createRing } from '../src/diag/ring.js';
import { createBufferedAmountTracker } from '../src/diag/buffered-amount.js';

describe('bounded ring buffer', () => {
  test('keeps only the most recent items once past capacity', () => {
    const ring = createRing(3);
    [1, 2, 3, 4, 5].forEach((item) => ring.push(item));
    expect(ring.list()).toEqual([3, 4, 5]);
    expect(ring.length).toBe(3);
  });
});

describe('buffered amount tracker', () => {
  test('tracks the observed max and counts sends left with backlog', () => {
    const tracker = createBufferedAmountTracker();
    [0, 120, 0, 4096, 12].forEach((value) => tracker.observe(value));
    expect(tracker.summary()).toEqual({ max: 4096, positiveSends: 3, sends: 5 });
  });
  test('ignores non-numeric or negative observations', () => {
    const tracker = createBufferedAmountTracker();
    tracker.observe(Number.NaN); tracker.observe(-5); tracker.observe(undefined as unknown as number);
    expect(tracker.summary()).toEqual({ max: 0, positiveSends: 0, sends: 0 });
  });
});
