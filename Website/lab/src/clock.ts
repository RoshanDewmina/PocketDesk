import { IO, type Ease } from "./ease";

export type Tok = { dead: boolean };
type Ticker = (dt: number) => void;

/**
 * One animation clock per demo. It stops while the demo is off screen or the tab is hidden, and every
 * tween and wait runs on its time, so a paused demo resumes exactly where it stopped.
 */
export class Clock {
  paused = true;
  time = 0;
  private visible = false;
  private tickers = new Set<Ticker>();
  private raf = 0;
  private last = 0;

  constructor(el: Element) {
    new IntersectionObserver((es) => {
      this.visible = es[es.length - 1]!.isIntersecting;
      this.sync();
    }).observe(el);
    document.addEventListener("visibilitychange", () => this.sync());
  }

  private sync() {
    const p = !this.visible || document.hidden;
    if (p === this.paused) return;
    this.paused = p;
    if (!p) this.start();
  }

  add(fn: Ticker) {
    this.tickers.add(fn);
    this.start();
    return () => {
      this.tickers.delete(fn);
    };
  }

  private start() {
    if (this.raf || this.paused || !this.tickers.size) return;
    this.last = 0;
    this.raf = requestAnimationFrame(this.frame);
  }

  private frame = (now: number) => {
    this.raf = 0;
    if (this.paused) return;
    const dt = this.last ? Math.min(50, now - this.last) : 16;
    this.last = now;
    this.time += dt;
    for (const f of [...this.tickers]) f(dt);
    if (this.tickers.size) this.raf = requestAnimationFrame(this.frame);
  };

  tween(ms: number, fn: (e: number) => void, tok: Tok, ease: Ease = IO): Promise<boolean> {
    return new Promise((res) => {
      if (tok.dead) return res(false);
      let el = 0;
      const off = this.add((dt) => {
        if (tok.dead) {
          off();
          return res(false);
        }
        el += dt;
        const t = ms <= 0 ? 1 : Math.min(1, el / ms);
        fn(ease(t));
        if (t >= 1) {
          off();
          res(true);
        }
      });
    });
  }

  wait(ms: number, tok: Tok) {
    return this.tween(ms, () => {}, tok, (t) => t);
  }
}
