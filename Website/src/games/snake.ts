// Snake on the footer's dot grid: an ember head, a bone body, and pulsing dots to reach for.

import { Game, isAction, type PointerKind, type Pt } from "./base";
import { BONE, EMBER, Sparks, TAU } from "./kit";

type Dir = 0 | 1 | 2 | 3;
const DX = [1, 0, -1, 0], DY = [0, 1, 0, -1];
const KEYS: Record<string, Dir> = { ArrowRight: 0, d: 0, ArrowDown: 1, s: 1, ArrowLeft: 2, a: 2, ArrowUp: 3, w: 3 };
type State = "ready" | "play" | "dead";

export class Snake extends Game {
  readonly id = "snake" as const;
  readonly name = "Snake";
  readonly help = "Snake. Steer the ember head to the bone dots; each one makes you longer. Arrow keys or W A S D steer, or swipe. Don't hit the edge or yourself. Escape leaves.";

  private state: State = "ready";
  private cs = 20;
  private cols = 0;
  private rows = 0;
  private ox = 0;
  private oy = 0;
  private body: number[] = [];
  private dir: Dir = 0;
  private queue: Dir[] = [];
  private food = -1;
  private acc = 0;
  private interval = 0.13;
  private score = 0;
  private swipe: Pt | null = null;
  private moved = false;
  private sparks = new Sparks(160, 200);

  protected reset() {
    const { w, h, c } = this;
    this.cs = c * 2;
    this.cols = Math.max(8, Math.floor(w / this.cs));
    this.rows = Math.max(6, Math.floor(h / this.cs));
    this.ox = (w - this.cols * this.cs) / 2;
    this.oy = (h - this.rows * this.cs) / 2;
    const mid = Math.floor(this.rows / 2) * this.cols + Math.floor(this.cols / 2);
    this.body = [mid, mid - 1, mid - 2, mid - 3];
    this.dir = 0;
    this.queue = [];
    this.score = 0;
    this.interval = 0.13;
    this.acc = 0;
    this.sparks.clear();
    this.place();
    this.state = "ready";
  }

  protected live() {
    return this.state === "play";
  }

  private place() {
    const taken = new Set(this.body);
    const free: number[] = [];
    for (let i = 0; i < this.cols * this.rows; i++) if (!taken.has(i)) free.push(i);
    this.food = free.length ? free[Math.floor(Math.random() * free.length)]! : -1;
  }

  private turn(d: Dir) {
    if (this.state === "ready") {
      if ((d + 2) % 4 === this.dir) return;
      this.state = "play";
      if (d === this.dir) return;
    }
    const last = this.queue.length ? this.queue[this.queue.length - 1]! : this.dir;
    if (d === last || (d + 2) % 4 === last || this.queue.length >= 2) return;
    this.queue.push(d);
  }

  protected tick(dt: number) {
    this.sparks.step(dt);
    if (this.state !== "play") return;
    this.acc += dt;
    while (this.acc >= this.interval && this.state === "play") {
      this.acc -= this.interval;
      this.advance();
    }
  }

  private advance() {
    if (this.queue.length) this.dir = this.queue.shift()!;
    const head = this.body[0]!;
    const hx = (head % this.cols) + DX[this.dir]!, hy = Math.floor(head / this.cols) + DY[this.dir]!;
    const next = hy * this.cols + hx;
    const eating = next === this.food;
    const hitsSelf = this.body.indexOf(next) > -1 && !(next === this.body[this.body.length - 1] && !eating);
    if (hx < 0 || hy < 0 || hx >= this.cols || hy >= this.rows || hitsSelf) {
      this.state = "dead";
      this.over = true;
      const [x, y] = this.at(head);
      this.sparks.burst(x, y, 14, this.cs * 9, EMBER, 0.6);
      const best = this.record(this.score);
      this.ui.say(`${hitsSelf ? "Tangled." : "Hit the edge."} Score ${this.score}.${best ? " A new best." : ""}`);
      return;
    }
    this.body.unshift(next);
    if (eating) {
      this.score++;
      this.interval = Math.max(0.065, this.interval - 0.003);
      const [x, y] = this.at(next);
      this.sparks.burst(x, y, 6, this.cs * 6, BONE, 0.45);
      this.place();
    } else this.body.pop();
  }

  private at(i: number): [number, number] {
    return [this.ox + ((i % this.cols) + 0.5) * this.cs, this.oy + (Math.floor(i / this.cols) + 0.5) * this.cs];
  }

  protected paint(ctx: CanvasRenderingContext2D) {
    const { ink, cs } = this;
    for (let i = 0; i < this.cols * this.rows; i++) {
      const [x, y] = this.at(i);
      ink.dot("rgba(237,232,223,0.16)", x, y, 1.3);
    }
    if (this.food >= 0) {
      const [x, y] = this.at(this.food);
      ink.dot(BONE, x, y, cs * (0.3 + 0.08 * Math.sin(performance.now() / 180)));
    }
    for (let k = this.body.length - 1; k >= 1; k--) {
      const [x, y] = this.at(this.body[k]!);
      ink.dot(BONE, x, y, cs * (0.36 - 0.08 * (k / this.body.length)));
    }
    this.sparks.draw(ink, cs * 0.16);
    ink.flush(ctx);
    const [x, y] = this.at(this.body[0]!);
    const g = ctx.createRadialGradient(x, y, 0, x, y, cs * 1.6);
    g.addColorStop(0, "rgba(255,91,31,0.45)");
    g.addColorStop(1, "rgba(255,91,31,0)");
    ctx.fillStyle = g;
    ctx.fillRect(x - cs * 1.6, y - cs * 1.6, cs * 3.2, cs * 3.2);
    ctx.fillStyle = EMBER;
    ctx.beginPath();
    ctx.arc(x, y, cs * 0.44, 0, TAU);
    ctx.fill();
  }

  protected status() {
    if (this.state === "ready") return this.act("Swipe to start. Swipe to steer.", "Arrow keys or W A S D to start and steer.");
    if (this.state === "dead") return `${this.score ? `${this.score} reached.` : "Nothing reached."} ${this.act("Tap", "Space")} for another go.`;
    return null;
  }

  protected hudText() {
    return `Score ${this.score}${this.best !== null ? ` · Best ${this.best}` : ""}`;
  }

  protected onKey(k: string, down: boolean, repeat: boolean) {
    const d = KEYS[k];
    if (d !== undefined) {
      if (down && this.state !== "dead") this.turn(d);
      return true;
    }
    if (isAction(k)) {
      if (down && !repeat && this.state === "dead") this.start();
      return true;
    }
    return false;
  }

  protected release() {
    this.swipe = null;
  }

  protected onPointer(kind: PointerKind, p: Pt) {
    if (kind === "down") {
      this.swipe = p;
      this.moved = false;
    } else if (kind === "move" && this.swipe) {
      const dx = p.x - this.swipe.x, dy = p.y - this.swipe.y;
      if (Math.hypot(dx, dy) < this.cs * 1.2) return;
      this.moved = true;
      if (this.state !== "dead") this.turn(Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? 0 : 2) : dy > 0 ? 1 : 3);
      this.swipe = p;
    } else if (kind === "up") {
      if (!this.moved && this.state === "dead") this.start();
      this.swipe = null;
    } else this.swipe = null;
  }
}
