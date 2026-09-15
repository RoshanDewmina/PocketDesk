import { createRing } from './ring.js';
import { createBufferedAmountTracker } from './buffered-amount.js';
import { extractCandidatePair, extractInboundVideo, createBitrateTracker } from './stats-sampler.js';
import { BENCH_KEY, BENCH_TIMEOUT_MS, crossedToward, meanLuminance, summarizeBench } from './bench.js';
import { resolveTile } from './params.js';

const MAX_STATS_SAMPLES = 3600;
const MAX_REPORT_BYTES = 512 * 1024;
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function createDiagController({ tile, benchCount, sendAction, getVideo, isFresh, getMarkerMode, statsIntervalMs = 1000, postSendGapMs = 250, sampleTile }) {
  const markerCost = createRing(2000);
  const bufferedAmount = createBufferedAmountTracker();
  const statsSamples = [];
  const bitrate = createBitrateTracker();
  let statsTimer;
  let tileCanvas;
  let latestBenchSummary;
  let currentRun;

  function recordMarkerCost(mode, t0, t1, t2, t3) {
    markerCost.push({ mode, drawMs: t1 - t0, getImageDataMs: t2 - t1, decodeMs: t3 - t2, totalMs: t3 - t0 });
  }
  function observeBufferedAmount(value) { bufferedAmount.observe(value); }

  function onTrack(peer) {
    stopSampling();
    statsTimer = setInterval(async () => {
      try {
        const entries = [...(await peer.getStats()).values()];
        const inbound = extractInboundVideo(entries);
        statsSamples.push({
          at: performance.now(),
          pair: extractCandidatePair(entries),
          inbound,
          bitrateBps: bitrate(inbound?.bytesReceived ?? null, performance.now()),
        });
        if (statsSamples.length > MAX_STATS_SAMPLES) statsSamples.shift();
      } catch { /* a transient getStats failure just skips this sample */ }
    }, statsIntervalMs);
  }
  function stopSampling() { clearInterval(statsTimer); statsTimer = undefined; }

  function defaultSampleTile(video, rect) {
    tileCanvas ??= document.createElement('canvas');
    if (tileCanvas.width !== rect.w || tileCanvas.height !== rect.h) { tileCanvas.width = rect.w; tileCanvas.height = rect.h; }
    const context = tileCanvas.getContext('2d', { willReadFrequently: true });
    context.drawImage(video, rect.x, rect.y, rect.w, rect.h, 0, 0, rect.w, rect.h);
    return meanLuminance(context.getImageData(0, 0, rect.w, rect.h));
  }
  const readTile = sampleTile ?? defaultSampleTile;

  function waitForCrossing(video, rect, expectBright, t0, run) {
    return new Promise((resolve) => {
      const tick = (now, metadata) => {
        if (run.aborted) { resolve({ status: 'aborted' }); return; }
        let luminance;
        try { luminance = readTile(video, rect); } catch { resolve({ status: 'error' }); return; }
        if (crossedToward(luminance, expectBright)) {
          resolve({ status: 'detected', latencyMs: now - t0, expectedDisplayTime: metadata?.expectedDisplayTime ?? null, presentationTime: metadata?.presentationTime ?? null });
          return;
        }
        if (now - t0 > BENCH_TIMEOUT_MS) { resolve({ status: 'timeout' }); return; }
        if (!video.requestVideoFrameCallback?.(tick)) resolve({ status: 'error' });
      };
      if (!video.requestVideoFrameCallback?.(tick)) resolve({ status: 'error' });
    });
  }

  // `run` is a per-invocation abort token: `abort()` flips the one currently in flight, so a
  // stale abort can never cancel a later, unrelated run.
  async function runLatencyBench() {
    const run = { aborted: false };
    currentRun = run;
    const video = getVideo();
    const rect = resolveTile(tile, video.videoWidth, video.videoHeight);
    const results = [];
    let expectBright;
    for (let index = 0; index < benchCount && !run.aborted; index += 1) {
      if (!isFresh()) { results.push({ status: 'stale' }); await wait(postSendGapMs); continue; }
      let baseline;
      try { baseline = readTile(video, rect); } catch { results.push({ status: 'error' }); await wait(postSendGapMs); continue; }
      if (expectBright === undefined) expectBright = !crossedToward(baseline, true);
      let t0;
      try { t0 = performance.now(); sendAction({ action: 'key', key: BENCH_KEY, modifiers: [] }); } catch { results.push({ status: 'error' }); await wait(postSendGapMs); continue; }
      results.push(await waitForCrossing(video, rect, expectBright, t0, run));
      if (run.aborted) break;
      expectBright = !expectBright;
      await wait(postSendGapMs);
    }
    if (currentRun === run) currentRun = undefined;
    latestBenchSummary = summarizeBench(results);
    return latestBenchSummary;
  }

  function abort() { if (currentRun) currentRun.aborted = true; }

  function buildReport() {
    return {
      userAgent: navigator.userAgent,
      viewport: { width: innerWidth, height: innerHeight },
      markerMode: getMarkerMode(),
      markerCost: markerCost.list(),
      bufferedAmount: bufferedAmount.summary(),
      stats: statsSamples.slice(),
      benchSummary: latestBenchSummary ?? null,
    };
  }

  async function sendReport() {
    const body = JSON.stringify(buildReport());
    if (new TextEncoder().encode(body).byteLength > MAX_REPORT_BYTES) throw new Error('Diagnostics report is too large');
    const response = await fetch('/api/diagnostics', { method: 'POST', headers: { 'content-type': 'application/json' }, body, credentials: 'omit', cache: 'no-store' });
    if (!response.ok) throw new Error(`Diagnostics upload was refused (${response.status})`);
  }

  return { recordMarkerCost, observeBufferedAmount, onTrack, stopSampling, runLatencyBench, abort, buildReport, sendReport };
}
