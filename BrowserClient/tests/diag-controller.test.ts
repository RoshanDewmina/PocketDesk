import { describe, expect, test } from 'bun:test';
import { createDiagController } from '../src/diag/controller.js';

function fakePeer(entries: Array<Record<string, unknown>> = []) {
  let calls = 0;
  return { calls: () => calls, getStats: async () => { calls += 1; return new Map(entries.map((entry) => [entry.id as string, entry])); } };
}

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe('diagnostics controller only samples getStats once told about a track', () => {
  test('a controller nobody calls onTrack on never polls getStats (the diag-disabled equivalent)', async () => {
    const peer = fakePeer();
    const controller = createDiagController({ tile: null, benchCount: 1, sendAction: () => {}, getVideo: () => ({}) as any, isFresh: () => true, getMarkerMode: () => 'crop', statsIntervalMs: 15 });
    await wait(60);
    expect(peer.calls()).toBe(0);
    controller.stopSampling();
  });

  test('onTrack starts a periodic sampler and stopSampling ends it for good', async () => {
    const peer = fakePeer([{ id: 't', type: 'transport' }]);
    const controller = createDiagController({ tile: null, benchCount: 1, sendAction: () => {}, getVideo: () => ({}) as any, isFresh: () => true, getMarkerMode: () => 'crop', statsIntervalMs: 15 });
    controller.onTrack(peer as any);
    await wait(70);
    const seenWhileRunning = peer.calls();
    expect(seenWhileRunning).toBeGreaterThan(1);
    controller.stopSampling();
    await wait(60);
    expect(peer.calls()).toBe(seenWhileRunning);
  });
});

// A fake video that mimics requestVideoFrameCallback/cancelVideoFrameCallback well enough to drive
// the bench's attempt state machine from tests. Every registration keeps a permanent, independently
// addressable slot (`fire(index, …)`) so a test can invoke an *earlier* registration's callback after
// later ones have already been registered or fired -- that is exactly how "stale callback" and "late
// response after timeout/cancel" races are reproduced deterministically.
function fakeVideo({ width = 640, height = 480 } = {}) {
  const callbacks: Array<{ callback: (now: number, metadata?: unknown) => void; cancelled: boolean }> = [];
  return {
    videoWidth: width, videoHeight: height,
    requestVideoFrameCallback(callback: (now: number, metadata?: unknown) => void) {
      callbacks.push({ callback, cancelled: false });
      return callbacks.length;
    },
    cancelVideoFrameCallback(handle: number) { const entry = callbacks[handle - 1]; if (entry) entry.cancelled = true; },
    // Invokes the callback registered at this 0-based index directly, even if it was since
    // "cancelled" -- a real browser's cancellation is a best-effort race, not a guarantee, and the
    // controller's own settled-guards (not this fake) are what must make a late call harmless.
    fire(index: number, now: number, metadata?: unknown) { callbacks[index]?.callback(now, metadata); },
    registrations: () => callbacks.length,
    pendingCount: () => callbacks.filter((c) => !c.cancelled).length,
  };
}

describe('runLatencyBench: baseline and post-send transition', () => {
  test('an attempt resolves via timeout when no frame callback ever arrives after the send', async () => {
    const video = fakeVideo();
    let sends = 0;
    const controller = createDiagController({
      tile: { x: 0, y: 0, w: 2, h: 2 }, benchCount: 1,
      sendAction: () => { sends += 1; },
      getVideo: () => video as any, isFresh: () => true, getMarkerMode: () => 'crop',
      sampleTile: () => 0,
      baselineTimeoutMs: 50, attemptTimeoutMs: 15, postSendGapMs: 1,
    });
    const runPromise = controller.runLatencyBench();
    expect(video.registrations()).toBe(1); // the baseline read is registered synchronously
    video.fire(0, performance.now());
    const summary = await runPromise;
    expect(sends).toBe(1);
    expect(summary).toMatchObject({ attempts: 1, n: 0, failures: { timeout: 1 } });
  });

  test('reports no_baseline and never sends when no frame is presented before the send', async () => {
    const video = fakeVideo();
    let sends = 0;
    const controller = createDiagController({
      tile: { x: 0, y: 0, w: 2, h: 2 }, benchCount: 1,
      sendAction: () => { sends += 1; },
      getVideo: () => video as any, isFresh: () => true, getMarkerMode: () => 'crop',
      baselineTimeoutMs: 15, attemptTimeoutMs: 15, postSendGapMs: 1,
    });
    const summary = await controller.runLatencyBench();
    expect(sends).toBe(0);
    expect(summary).toMatchObject({ attempts: 1, n: 0, failures: { no_baseline: 1 } });
  });

  test('ignores a frame presented before the send and only detects a genuine post-send crossing', async () => {
    const video = fakeVideo();
    let luminance = 0;
    const controller = createDiagController({
      tile: { x: 0, y: 0, w: 2, h: 2 }, benchCount: 1,
      sendAction: () => { luminance = 255; },
      getVideo: () => video as any, isFresh: () => true, getMarkerMode: () => 'crop',
      sampleTile: () => luminance,
      baselineTimeoutMs: 50, attemptTimeoutMs: 50, postSendGapMs: 1,
    });
    const beforeSend = performance.now();
    const runPromise = controller.runLatencyBench();
    video.fire(0, beforeSend); // baseline: dark
    await wait(2);
    // A stale-looking frame stamped at/near the pre-send time, even though it already reads bright,
    // must not count -- it was queued before the send, so the wait keeps going instead of resolving.
    video.fire(1, beforeSend);
    await wait(2);
    expect(video.registrations()).toBe(3); // the transition wait re-registered after ignoring it
    const afterSend = performance.now();
    video.fire(2, afterSend, { presentationTime: afterSend });
    const summary = await runPromise;
    expect(summary.metric).toBe('browser-send to presented-frame response');
    expect(summary.n).toBe(1);
    expect(summary.attempts).toBe(1);
  });

  test('a stale callback from a timed-out attempt does not affect the next attempt', async () => {
    const video = fakeVideo();
    let luminance = 0;
    let sends = 0;
    const controller = createDiagController({
      tile: { x: 0, y: 0, w: 2, h: 2 }, benchCount: 2,
      sendAction: () => { sends += 1; luminance = luminance > 127.5 ? 0 : 255; },
      getVideo: () => video as any, isFresh: () => true, getMarkerMode: () => 'crop',
      sampleTile: () => luminance,
      baselineTimeoutMs: 50, attemptTimeoutMs: 15, postSendGapMs: 1,
    });
    const runPromise = controller.runLatencyBench();
    video.fire(0, performance.now()); // attempt 1 baseline: dark
    await wait(2); // attempt 1 sends, registers its transition wait (index 1), which is left unfired
    await wait(30); // attempt 1's transition wait times out
    video.fire(2, performance.now()); // attempt 2 baseline: bright (left over from attempt 1's send)
    await wait(2);
    // The stale attempt-1 transition callback (index 1) fires very late, falsely claiming a crossing.
    video.fire(1, performance.now(), { presentationTime: performance.now() });
    await wait(2);
    const afterSend = performance.now();
    video.fire(3, afterSend, { presentationTime: afterSend }); // attempt 2's genuine transition: dark
    const summary = await runPromise;
    expect(sends).toBe(2);
    expect(summary.attempts).toBe(2);
    expect(summary.failures).toEqual({ timeout: 1 });
    expect(summary.n).toBe(1); // only attempt 2's genuine, correctly-timed frame counts
  });

  test('a tile read that resolves after the attempt already timed out is dropped', async () => {
    const video = fakeVideo();
    let resolveLateRead: ((value: number) => void) | undefined;
    let call = 0;
    const controller = createDiagController({
      tile: { x: 0, y: 0, w: 2, h: 2 }, benchCount: 1,
      sendAction: () => {},
      getVideo: () => video as any, isFresh: () => true, getMarkerMode: () => 'crop',
      sampleTile: () => {
        call += 1;
        if (call === 1) return 0; // synchronous baseline read
        return new Promise<number>((resolve) => { resolveLateRead = resolve; });
      },
      baselineTimeoutMs: 50, attemptTimeoutMs: 15, postSendGapMs: 1,
    });
    const runPromise = controller.runLatencyBench();
    video.fire(0, performance.now()); // baseline
    await wait(2);
    video.fire(1, performance.now()); // starts the post-send read, which hangs
    await wait(30); // the attempt's timer fires while the read is still pending
    resolveLateRead?.(255); // the read finally resolves, showing a "crossed" value, too late
    await wait(2);
    const summary = await runPromise;
    expect(summary).toMatchObject({ attempts: 1, n: 0, failures: { timeout: 1 } });
  });

  test('a late frame after timeout does not retroactively register a wrong-polarity success', async () => {
    const video = fakeVideo();
    let luminance = 0;
    const controller = createDiagController({
      tile: { x: 0, y: 0, w: 2, h: 2 }, benchCount: 1,
      sendAction: () => { luminance = 255; },
      getVideo: () => video as any, isFresh: () => true, getMarkerMode: () => 'crop',
      sampleTile: () => luminance,
      baselineTimeoutMs: 50, attemptTimeoutMs: 15, postSendGapMs: 1,
    });
    const runPromise = controller.runLatencyBench();
    video.fire(0, performance.now()); // baseline: dark
    await wait(30); // the transition wait times out with no frame delivered
    // A "cancelled" callback fires anyway (best-effort real-world cancellation), now correctly
    // showing the flip -- this must not turn the already-settled timeout into a success.
    video.fire(1, performance.now(), { presentationTime: performance.now() });
    const summary = await runPromise;
    expect(summary).toMatchObject({ attempts: 1, n: 0, failures: { timeout: 1 } });
  });

  test('aggregates a run with a stale skip, a timeout, and a success', async () => {
    const video = fakeVideo();
    let freshCall = 0;
    let luminance = 0;
    const controller = createDiagController({
      tile: { x: 0, y: 0, w: 2, h: 2 }, benchCount: 3,
      sendAction: () => { luminance = luminance > 127.5 ? 0 : 255; },
      getVideo: () => video as any,
      isFresh: () => { freshCall += 1; return freshCall !== 1; },
      getMarkerMode: () => 'crop',
      sampleTile: () => luminance,
      baselineTimeoutMs: 50, attemptTimeoutMs: 15, postSendGapMs: 1,
    });
    const runPromise = controller.runLatencyBench();
    await wait(2); // attempt 1 is skipped as stale; attempt 2 registers its baseline (index 0)
    video.fire(0, performance.now()); // attempt 2 baseline: dark
    await wait(2); // attempt 2 sends and registers its transition wait (index 1), left unfired
    await wait(30); // attempt 2's transition wait times out
    video.fire(2, performance.now()); // attempt 3 baseline: bright (left over from attempt 2's send)
    await wait(2);
    const afterSend = performance.now();
    video.fire(3, afterSend, { presentationTime: afterSend }); // attempt 3's transition: dark
    const summary = await runPromise;
    expect(summary.attempts).toBe(3);
    expect(summary.n).toBe(1);
    expect(summary.failures).toEqual({ stale: 1, timeout: 1 });
  });
});

describe('runLatencyBench stops sending once aborted', () => {
  test('abort() prevents any further key sends and lets the in-flight wait resolve as cancelled', async () => {
    const video = fakeVideo();
    let sends = 0;
    const controller = createDiagController({
      tile: { x: 0, y: 0, w: 5, h: 5 },
      benchCount: 5,
      sendAction: () => { sends += 1; },
      getVideo: () => video as any,
      isFresh: () => true,
      getMarkerMode: () => 'crop',
      sampleTile: () => 0,
      baselineTimeoutMs: 50, attemptTimeoutMs: 50,
      postSendGapMs: 1,
    });
    const runPromise = controller.runLatencyBench();
    video.fire(0, performance.now()); // baseline
    await wait(2);
    expect(sends).toBe(1);
    expect(video.registrations()).toBe(2); // baseline + transition wait
    controller.abort();
    video.fire(1, performance.now()); // deliver a frame to the now-aborted transition wait
    const summary = await runPromise;
    expect(sends).toBe(1);
    expect(summary).toEqual({
      metric: 'browser-send to presented-frame response',
      attempts: 1,
      n: 0,
      median: null,
      p95: null,
      max: null,
      failures: { cancelled: 1 },
    });
  });

  test('abort() on an already-finished run is a harmless no-op for the next run', async () => {
    const controller = createDiagController({
      tile: { x: 0, y: 0, w: 2, h: 2 }, benchCount: 0,
      sendAction: () => { throw new Error('should not be called'); },
      getVideo: () => fakeVideo() as any,
      isFresh: () => true,
      getMarkerMode: () => 'crop',
      sampleTile: () => 0,
      postSendGapMs: 1,
    });
    await controller.runLatencyBench();
    expect(() => controller.abort()).not.toThrow();
  });
});

describe('createDiagController parameter validation', () => {
  const base = { tile: null, sendAction: () => {}, getVideo: () => ({}) as any, isFresh: () => true, getMarkerMode: () => 'crop' };

  test('rejects a non-integer or out-of-range benchCount', () => {
    expect(() => createDiagController({ ...base, benchCount: 1.5 })).toThrow(/benchCount/);
    expect(() => createDiagController({ ...base, benchCount: -1 })).toThrow(/benchCount/);
    expect(() => createDiagController({ ...base, benchCount: 1001 })).toThrow(/benchCount/);
  });

  test('rejects an invalid sampling interval', () => {
    expect(() => createDiagController({ ...base, benchCount: 1, statsIntervalMs: 0 })).toThrow(/statsIntervalMs/);
    expect(() => createDiagController({ ...base, benchCount: 1, statsIntervalMs: 1.2 })).toThrow(/statsIntervalMs/);
  });

  test('rejects an invalid post-send gap', () => {
    expect(() => createDiagController({ ...base, benchCount: 1, postSendGapMs: -1 })).toThrow(/postSendGapMs/);
  });

  test('rejects invalid baseline or attempt timeouts', () => {
    expect(() => createDiagController({ ...base, benchCount: 1, baselineTimeoutMs: 0 })).toThrow(/baselineTimeoutMs/);
    expect(() => createDiagController({ ...base, benchCount: 1, attemptTimeoutMs: 0 })).toThrow(/attemptTimeoutMs/);
    expect(() => createDiagController({ ...base, benchCount: 1, attemptTimeoutMs: 60_001 })).toThrow(/attemptTimeoutMs/);
  });

  test('accepts a valid configuration, including the benchCount: 0 edge case', () => {
    expect(() => createDiagController({ ...base, benchCount: 0 })).not.toThrow();
  });
});
