export function createBufferedAmountTracker() {
  let max = 0, positiveSends = 0, sends = 0;
  return {
    observe(value) {
      if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return;
      sends += 1; if (value > 0) positiveSends += 1; if (value > max) max = value;
    },
    summary() { return { max, positiveSends, sends }; },
  };
}
