import { describe, expect, test } from 'bun:test';
import { crossedToward, meanLuminance, runBenchSequence, summarizeBench } from '../src/diag/bench.js';

describe('tile luminance', () => {
  test('averages RGB across every pixel and ignores alpha', () => {
    const data = new Uint8ClampedArray([0, 0, 0, 255, 255, 255, 255, 0]);
    expect(meanLuminance({ data })).toBe(127.5);
  });
  test('is null for missing or empty image data', () => {
    expect(meanLuminance(null)).toBeNull();
    expect(meanLuminance({ data: new Uint8ClampedArray() })).toBeNull();
  });
});

describe('crossedToward', () => {
  test('respects the expected direction against the midpoint', () => {
    expect(crossedToward(200, true)).toBe(true);
    expect(crossedToward(50, true)).toBe(false);
    expect(crossedToward(50, false)).toBe(true);
    expect(crossedToward(200, false)).toBe(false);
  });
  test('never crosses on a non-finite reading', () => expect(crossedToward(Number.NaN, true)).toBe(false));
});

describe('runBenchSequence', () => {
  test('detects the first frame crossing toward the expected state and carries its metadata', () => {
    const samples = [{ now: 5, luminance: 40 }, { now: 25, luminance: 60 }, { now: 45, luminance: 200, expectedDisplayTime: 46 }];
    expect(runBenchSequence({ samples, expectBright: true, t0: 0 })).toEqual({ status: 'detected', latencyMs: 45, expectedDisplayTime: 46, presentationTime: null });
  });
  test('times out when nothing crosses inside the window', () => {
    const samples = [{ now: 10, luminance: 40 }, { now: 1600, luminance: 200 }];
    expect(runBenchSequence({ samples, expectBright: true, t0: 0 })).toEqual({ status: 'timeout' });
  });
  test('a late sample past the timeout does not count even if it would cross', () => {
    const samples = [{ now: 1501, luminance: 255 }];
    expect(runBenchSequence({ samples, expectBright: true, t0: 0, timeoutMs: 1500 })).toEqual({ status: 'timeout' });
  });
});

describe('summarizeBench', () => {
  test('computes median, p95, max and counts timeouts/stale/errors separately', () => {
    const results = [
      { status: 'detected', latencyMs: 10 }, { status: 'detected', latencyMs: 20 }, { status: 'detected', latencyMs: 30 },
      { status: 'timeout' }, { status: 'stale' }, { status: 'error' },
    ];
    expect(summarizeBench(results)).toEqual({ n: 3, median: 20, p95: 30, max: 30, timeouts: 1, staleRejects: 1, errors: 0 + 1 });
  });
  test('handles a run with no detections at all', () => {
    expect(summarizeBench([{ status: 'timeout' }, { status: 'stale' }])).toEqual({ n: 0, median: null, p95: null, max: null, timeouts: 1, staleRejects: 1, errors: 0 });
  });
});
