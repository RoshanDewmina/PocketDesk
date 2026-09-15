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

function fakeVideo() {
  const ticks: Array<(now: number, meta?: unknown) => void> = [];
  return {
    videoWidth: 640, videoHeight: 480,
    requestVideoFrameCallback(callback: (now: number, meta?: unknown) => void) { ticks.push(callback); return ticks.length; },
    fire(now: number) { const callback = ticks.shift(); callback?.(now); },
    pendingTicks: () => ticks.length,
  };
}

describe('runLatencyBench stops sending once aborted', () => {
  test('abort() prevents any further key sends and lets the in-flight wait resolve', async () => {
    const video = fakeVideo();
    let sends = 0;
    const controller = createDiagController({
      tile: { x: 0, y: 0, w: 2, h: 2 }, benchCount: 5,
      sendAction: () => { sends += 1; },
      getVideo: () => video as any,
      isFresh: () => true,
      getMarkerMode: () => 'crop',
      sampleTile: () => 0,
      postSendGapMs: 1,
    });
    const runPromise = controller.runLatencyBench();
    expect(sends).toBe(1);
    expect(video.pendingTicks()).toBe(1);
    controller.abort();
    video.fire(10);
    const summary = await runPromise;
    expect(sends).toBe(1);
    expect(video.pendingTicks()).toBe(0);
    expect(summary.n + summary.timeouts + summary.staleRejects + summary.errors).toBeLessThan(5);
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
