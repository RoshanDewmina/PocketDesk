export const BENCH_KEY = 'space';
export const MIDPOINT_LUMINANCE = 127.5;
export const BENCH_TIMEOUT_MS = 1500;

export function meanLuminance(imageData) {
  if (!imageData || !(imageData.data instanceof Uint8ClampedArray) || imageData.data.length === 0) return null;
  const { data } = imageData;
  let sum = 0;
  for (let index = 0; index < data.length; index += 4) sum += (data[index] + data[index + 1] + data[index + 2]) / 3;
  return sum / (data.length / 4);
}

export function crossedToward(luminance, expectBright) {
  if (typeof luminance !== 'number' || !Number.isFinite(luminance)) return false;
  return expectBright ? luminance > MIDPOINT_LUMINANCE : luminance < MIDPOINT_LUMINANCE;
}

// samples: [{ now, luminance, expectedDisplayTime?, presentationTime? }], each `now` on the same clock as t0.
export function runBenchSequence({ samples, expectBright, t0, timeoutMs = BENCH_TIMEOUT_MS }) {
  for (const sample of samples) {
    const elapsed = sample.now - t0;
    if (elapsed > timeoutMs) break;
    if (crossedToward(sample.luminance, expectBright)) {
      return { status: 'detected', latencyMs: elapsed, expectedDisplayTime: sample.expectedDisplayTime ?? null, presentationTime: sample.presentationTime ?? null };
    }
  }
  return { status: 'timeout' };
}

function percentile(sorted, fraction) {
  return sorted.length === 0 ? null : sorted[Math.min(sorted.length - 1, Math.floor(fraction * sorted.length))];
}

// median/p95/max are computed over successful ("detected") attempts only; every other status is a
// failure reason and is counted in `failures` instead, so a run of mostly timeouts can't drag the
// latency numbers toward misleadingly small (or absent) values.
export function summarizeBench(results) {
  const latencies = results.filter((r) => r.status === 'detected').map((r) => r.latencyMs).sort((a, b) => a - b);
  const failures = {};
  for (const result of results) {
    if (result.status === 'detected') continue;
    failures[result.status] = (failures[result.status] ?? 0) + 1;
  }
  return {
    attempts: results.length,
    n: latencies.length,
    median: percentile(latencies, 0.5),
    p95: percentile(latencies, 0.95),
    max: latencies.length ? latencies[latencies.length - 1] : null,
    failures,
  };
}
