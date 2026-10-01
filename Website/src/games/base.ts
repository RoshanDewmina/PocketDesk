// What every footer game shares: a world sized to the wordmark band when the run starts (drawn scaled if the
// band later changes, so a resize or rotation never resets progress), pause handling, and the text overlay.

import { coarse, Ink, loadBest, saveBest } from "./kit";
import type { Host, Rect, Runner } from "./types";

export type GameId = "breakout" | "reach" | "lander" | "snake";

/** The real-text layer over the canvas (src/games/arcade.ts). Setters skip unchanged text. */
export interface Ui {
  hud(t: string): void;
  msg(t: string | null): void;
  big(n: string | null, unit?: string): void;
  cap(t: string | null): void;
  say(t: string): void;
}

export type Pt = { x: number; y: number };
export type PointerKind = "down" | "move" | "up" | "cancel";

export const isAction = (k: string) => k === " " || k === "Enter";
export const keyName = (e: KeyboardEvent) => (e.key.length === 1 ? e.key.toLowerCase() : e.key);

export abstract class Game implements Runner {
  abstract readonly id: GameId;
  abstract readonly name: string;
  /** For screen readers: what the game is and how to play it. */
  abstract readonly help: string;
  /** Lower is better (Reach), otherwise higher. */
  protected lowerIsBetter = false;

  over = false;
  paused = false;
  protected w = 0;
  protected h = 0;
  /** Dot pitch of the field when the run started. */
  protected c = 10;
  protected band: Rect = { x: 0, y: 0, w: 0, h: 0 };
  protected sx = 1;
  protected sy = 1;
  protected best: number | null = null;
  protected ink = new Ink();
  protected touch = coarse();

  constructor(protected host: Host, protected ui: Ui) {}

  start() {
    const g = this.host.geo();
    this.band = g.band;
    this.w = g.band.w;
    this.h = g.band.h;
    this.c = g.step;
    this.sx = this.sy = 1;
    this.over = false;
    this.paused = false;
    this.touch = coarse();
    this.best = loadBest(this.id);
    this.ui.big(null);
    this.ui.cap(null);
    this.reset();
  }

  layout() {
    const b = this.host.geo().band;
    this.band = b;
    if (this.w && this.h) {
      this.sx = b.w / this.w;
      this.sy = b.h / this.h;
    }
  }

  suspend() {
    this.release();
    if (!this.over && this.live()) this.paused = true;
  }

  /** Let go of held keys and fingers (their key-up may never arrive once focus has gone). */
  protected release() {}

  resume() {
    this.paused = false;
  }

  step(dtMs: number) {
    if (this.paused) return;
    this.tick(dtMs / 1000);
  }

  draw(ctx: CanvasRenderingContext2D) {
    ctx.save();
    ctx.translate(this.band.x, this.band.y);
    ctx.scale(this.sx, this.sy);
    this.paint(ctx);
    ctx.restore();
    this.ui.msg(this.paused ? (this.touch ? "Paused. Tap to go on." : "Paused. Press Space to go on.") : this.status());
    this.ui.hud(this.hudText());
  }

  key(e: KeyboardEvent, down: boolean): boolean {
    const k = keyName(e);
    if (this.paused) {
      if (down && isAction(k)) {
        this.resume();
        return true;
      }
      return isAction(k) || k.startsWith("Arrow");
    }
    return this.onKey(k, down, e.repeat, e.timeStamp || performance.now());
  }

  pointer(kind: PointerKind, p: Pt, e: PointerEvent) {
    if (this.paused) {
      if (kind === "down") this.resume();
      return;
    }
    this.onPointer(kind, { x: (p.x - this.band.x) / this.sx, y: (p.y - this.band.y) / this.sy }, e);
  }

  /** Record a finished run's score; true if it is a new best. */
  protected record(v: number) {
    const better = this.best === null || (this.lowerIsBetter ? v < this.best : v > this.best);
    if (better && v > 0) {
      this.best = Math.round(v);
      saveBest(this.id, v);
    }
    return better && v > 0;
  }

  protected act(touch: string, keys: string) {
    return this.touch ? touch : keys;
  }

  /** Is anything in motion that a pause would interrupt? */
  protected live() {
    return true;
  }

  protected abstract reset(): void;
  protected abstract tick(dt: number): void;
  protected abstract paint(ctx: CanvasRenderingContext2D): void;
  protected abstract status(): string | null;
  protected abstract hudText(): string;
  protected abstract onKey(k: string, down: boolean, repeat: boolean, at: number): boolean;
  protected abstract onPointer(kind: PointerKind, p: Pt, e: PointerEvent): void;
}
