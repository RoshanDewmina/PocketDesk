import { createRing } from './ring.js';
import { createBufferedAmountTracker } from './buffered-amount.js';
import { extractCandidatePair, extractInboundVideo, createBitrateTracker } from './stats-sampler.js';
import { BENCH_KEY, BENCH_TIMEOUT_MS, crossedToward, meanLuminance, summarizeBench } from './bench.js';
import { resolveTile } from './params.js';

const MAX_STATS_SAMPLES = 3600;
const MAX_REPORT_BYTES = 512 * 1024;
const DEFAULT_BASELINE_TIMEOUT_MS = 300;
const BENCH_METRIC = 'browser-send to presented-frame response';
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function boundedInteger(name, value, minimum, maximum) {
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer between ${minimum} and ${maximum} (received ${value})`);
  }
  return value;
}

export function createDiagController({
  tile, benchCount, sendAction, getVideo, isFresh, getMarkerMode,
  statsIntervalMs = 1000, postSendGapMs = 250, sampleTile,
  baselineTimeoutMs = DEFAULT_BASELINE_TIMEOUT_MS, attemptTimeoutMs = BENCH_TIMEOUT_MS,
}) {
  boundedInteger('benchCount', benchCount, 0, 1000);
  boundedInteger('statsIntervalMs', statsIntervalMs, 1, 60_000);
  boundedInteger('postSendGapMs', postSendGapMs, 0, 60_000);
  boundedInteger('baselineTimeoutMs', baselineTimeoutMs, 1, 60_000);
  boundedInteger('attemptTimeoutMs', attemptTimeoutMs, 1, 60_000);

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

  // Presentation time on the same clock as `t0` (performance.now()): prefer the frame callback's
  // own metadata.presentationTime when the browser supplies one, otherwise fall back to the
  // callback's `now` argument, which rVFC guarantees is on that same clock.
  function presentationTime(now, metadata) {
    return typeof metadata?.presentationTime === 'number' ? metadata.presentationTime : now;
  }

  // Waits for exactly one presented frame and samples the tile on it, bounded by `timeoutMs` via a
  // real timer so the promise still settles when no frame callback ever fires. `settled` scopes
  // every guard to this single call: a callback or async tile-read that resolves after this promise
  // has already settled (timeout, or the shared `run` token was aborted) is a no-op, so it can never
  // bleed into a later attempt's baseline.
  function observeFrame(video, rect, timeoutMs, run) {
    return new Promise((resolve) => {
      let settled = false;
      let handle;
      const finish = (value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (handle !== undefined) video.cancelVideoFrameCallback?.(handle);
        resolve(value);
      };
      const timer = setTimeout(() => finish(null), timeoutMs);
      const tick = async (now, metadata) => {
        if (settled) return;
        const presentedAt = presentationTime(now, metadata);
        let luminance;
        try { luminance = await readTile(video, rect); } catch { finish(null); return; }
        if (settled || run.aborted) { finish(null); return; }
        finish({ luminance, presentedAt });
      };
      handle = video.requestVideoFrameCallback?.(tick);
      if (handle === undefined) finish(null);
    });
  }

  // Waits for a frame *presented after* `t0` to show the tile having crossed into `expectBright` --
  // a frame already queued before the send is ignored and the wait keeps going. Bounded by
  // `timeoutMs` via a real timer independent of the frame callback chain, so it resolves even if no
  // frame (or no further frame) ever arrives. Once settled, any later callback or tile-read --
  // including one that would show the tile flipping back to the wrong polarity -- is dropped rather
  // than retroactively turned into a success.
  function waitForTransition(video, rect, expectBright, t0, timeoutMs, run) {
    return new Promise((resolve) => {
      let settled = false;
      let handle;
      const finish = (value) => {
        if (settled) return;
        settled = true;
        clearTimeout(deadline);
        if (handle !== undefined) video.cancelVideoFrameCallback?.(handle);
        resolve(value);
      };
      const deadline = setTimeout(() => finish({ status: 'timeout' }), timeoutMs);
      const tick = async (now, metadata) => {
        if (settled) return;
        const presentedAt = presentationTime(now, metadata);
        let luminance;
        try { luminance = await readTile(video, rect); } catch { finish({ status: 'error' }); return; }
        if (settled) return;
        if (run.aborted) { finish({ status: 'cancelled' }); return; }
        if (presentedAt > t0 && crossedToward(luminance, expectBright)) {
          finish({ status: 'detected', latencyMs: presentedAt - t0, expectedDisplayTime: metadata?.expectedDisplayTime ?? null, presentationTime: metadata?.presentationTime ?? null });
          return;
        }
        handle = video.requestVideoFrameCallback?.(tick);
        if (handle === undefined) finish({ status: 'error' });
      };
      handle = video.requestVideoFrameCallback?.(tick);
      if (handle === undefined) finish({ status: 'error' });
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
    for (let index = 0; index < benchCount && !run.aborted; index += 1) {
      if (!isFresh()) { results.push({ status: 'stale' }); await wait(postSendGapMs); continue; }

      // Every attempt observes its own pre-send baseline frame rather than trusting a toggled flag
      // carried over from the previous attempt, so a missed transition can never desync expectBright.
      const baseline = await observeFrame(video, rect, baselineTimeoutMs, run);
      if (run.aborted) { results.push({ status: 'cancelled' }); break; }
      if (!baseline) { results.push({ status: 'no_baseline' }); await wait(postSendGapMs); continue; }
      const expectBright = !crossedToward(baseline.luminance, true);

      let t0;
      try { t0 = performance.now(); sendAction({ action: 'key', key: BENCH_KEY, modifiers: [] }); }
      catch { results.push({ status: 'send_failed' }); await wait(postSendGapMs); continue; }

      results.push(await waitForTransition(video, rect, expectBright, t0, attemptTimeoutMs, run));
      if (run.aborted) break;
      await wait(postSendGapMs);
    }
    if (currentRun === run) currentRun = undefined;
    latestBenchSummary = { metric: BENCH_METRIC, ...summarizeBench(results) };
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
