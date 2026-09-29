import type { ServiceClock } from '../src/server';

type Scheduled = { at: number; callback: () => void };

const settle = () => new Promise<void>(resolve => setTimeout(resolve, 5));

/**
 * A manual clock for the signaling service. Only the service's protocol lifetimes run on it; the
 * WebSocket traffic in a test is still real, so every step waits briefly for real I/O to settle.
 */
export class FakeClock implements ServiceClock {
  private current: number;
  private nextHandle = 1;
  private readonly timers = new Map<number, Scheduled>();

  constructor(start = Date.UTC(2026, 8, 29, 12, 0, 0)) { this.current = start; }

  now() { return this.current; }

  setTimeout(callback: () => void, ms: number) {
    const handle = this.nextHandle++;
    this.timers.set(handle, { at: this.current + Math.max(0, ms), callback });
    return handle;
  }

  clearTimeout(handle: unknown) {
    if (typeof handle === 'number') this.timers.delete(handle);
  }

  get pendingTimers() { return this.timers.size; }

  /** Moves time forward, firing every timer that falls due on the way, in order. */
  async advance(ms: number) {
    const target = this.current + ms;
    for (;;) {
      let next: [number, Scheduled] | undefined;
      for (const entry of this.timers) {
        if (entry[1].at <= target && (!next || entry[1].at < next[1].at)) next = entry;
      }
      if (!next) break;
      this.timers.delete(next[0]);
      this.current = Math.max(this.current, next[1].at);
      next[1].callback();
      await settle();
    }
    this.current = target;
    await settle();
  }

  /** Moves time forward without running due timers, like an event loop that was blocked for a while. */
  stall(ms: number) { this.current += ms; }
}
