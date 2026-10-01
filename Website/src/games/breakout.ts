// Breakout: the wordmark is the wall. Its dots are cut into small clusters (the bricks); hits heat the bricks
// around them and burst the one struck. The paddle is a bone trackpad bar, the ball an ember dot with a trail.

import { Game, isAction, type PointerKind, type Pt } from "./base";
import { BONE, clamp, EMBER, heatColor, rand, Sparks, TAU, wordCells } from "./kit";

const BALLS = 3;
type State = "ready" | "play" | "won" | "lost";

export class Breakout extends Game {
  readonly id = "breakout" as const;
  readonly name = "Breakout";
  readonly help = "Breakout. The farside wordmark is a wall of dots; bounce the ember ball off the bar to clear it. Left and right arrows or the pointer move the bar, Space launches, Escape leaves.";

  private state: State = "ready";
  private bs = 20;
  private cols = 0;
  private rows = 0;
  private ox = 0;
  private alive = new Uint8Array(0);
  private ink1 = new Float32Array(0);
  private dcols = 0;
  private heat = new Float32Array(0);
  private left = 0;
  private total = 0;
  private score = 0;
  private balls = BALLS;
  private combo = 0;
  private px = 0;
  private pw = 100;
  private py = 0;
  private ph = 8;
  private bx = 0;
  private by = 0;
  private vx = 0;
  private vy = 0;
  private r = 5;
  private speed = 300;
  private trail: Pt[] = [];
  private keys = { l: false, r: false };
  private aim: number | null = null;
  private down: { x: number; y: number; moved: boolean } | null = null;
  private sparks = new Sparks(360, 600);

  protected reset() {
    const { w, h, c } = this;
    this.bs = c * 2;
    // The word is sampled dot by dot (as the field draws it); bricks are 2 × 2 dots, and draw only their inked dots.
    const g = wordCells(w, h, c, { x: w * 0.03, y: h * 0.04, w: w * 0.94, h: h * 0.5 });
    this.dcols = g.cols;
    this.ink1 = g.cov.map((v) => (v > 0.12 ? v : 0));
    this.cols = Math.ceil(g.cols / 2);
    this.rows = Math.ceil(g.rows / 2);
    this.ox = (w - g.cols * c) / 2;
    this.alive = new Uint8Array(this.cols * this.rows);
    this.heat = new Float32Array(this.cols * this.rows);
    let n = 0;
    for (let i = 0; i < g.cov.length; i++) {
      if (!this.ink1[i]) continue;
      const b = Math.floor(Math.floor(i / g.cols) / 2) * this.cols + Math.floor((i % g.cols) / 2);
      if (!this.alive[b]) (this.alive[b] = 1), n++;
    }
    this.left = this.total = n;
    this.score = 0;
    this.balls = BALLS;
    this.pw = clamp(w * 0.15, 64, 170);
    this.ph = Math.max(6, c * 0.75);
    this.py = h - this.ph - c * 0.9;
    this.px = w / 2;
    this.r = Math.max(4, c * 0.5);
    this.speed = clamp(h * 0.95, 230, 470);
    this.sparks.clear();
    this.serve();
  }

  private serve() {
    this.state = "ready";
    this.combo = 0;
    this.trail.length = 0;
    this.bx = this.px;
    this.by = this.py - this.r - 1;
  }

  private launch() {
    const a = -Math.PI / 2 + rand(-0.45, 0.45);
    this.vx = Math.cos(a) * this.speed;
    this.vy = Math.sin(a) * this.speed;
    this.state = "play";
  }

  protected live() {
    return this.state === "play" || this.state === "ready";
  }

  protected tick(dt: number) {
    const { w } = this;
    const move = w * 0.95 * dt;
    if (this.keys.l) this.px -= move;
    if (this.keys.r) this.px += move;
    if (this.aim !== null) this.px += (this.aim - this.px) * Math.min(1, dt * 22);
    this.px = clamp(this.px, this.pw / 2, w - this.pw / 2);
    for (let i = 0; i < this.heat.length; i++) if (this.heat[i]! > 0) this.heat[i] = Math.max(0, this.heat[i]! - dt * 1.1);
    this.sparks.step(dt);
    if (this.state === "ready") {
      this.bx = this.px;
      this.by = this.py - this.r - 1;
      return;
    }
    if (this.state !== "play") return;

    const dist = Math.hypot(this.vx, this.vy) * dt;
    const n = Math.max(1, Math.ceil(dist / (this.r * 0.5)));
    const h1 = dt / n;
    for (let s = 0; s < n && this.state === "play"; s++) this.move(h1);
    this.trail.unshift({ x: this.bx, y: this.by });
    if (this.trail.length > 9) this.trail.pop();
  }

  private move(dt: number) {
    const { w, h, r } = this;
    this.bx += this.vx * dt;
    if (this.bx < r) (this.bx = r), (this.vx = Math.abs(this.vx));
    if (this.bx > w - r) (this.bx = w - r), (this.vx = -Math.abs(this.vx));
    if (this.hitAt(this.bx + Math.sign(this.vx) * r, this.by)) {
      this.bx -= this.vx * dt;
      this.vx = -this.vx;
    }
    this.by += this.vy * dt;
    if (this.by < r) (this.by = r), (this.vy = Math.abs(this.vy));
    if (this.hitAt(this.bx, this.by + Math.sign(this.vy) * r)) {
      this.by -= this.vy * dt;
      this.vy = -this.vy;
    }
    // The bar: the bounce angle follows where on the bar the ball lands.
    if (this.vy > 0 && this.by + r >= this.py && this.by + r <= this.py + this.ph + this.vy * dt + 1 && Math.abs(this.bx - this.px) <= this.pw / 2 + r) {
      const off = clamp((this.bx - this.px) / (this.pw / 2), -1, 1);
      const a = -Math.PI / 2 + off * 1.05;
      const sp = Math.hypot(this.vx, this.vy);
      this.vx = Math.cos(a) * sp;
      this.vy = Math.sin(a) * sp;
      this.by = this.py - r;
      this.combo = 0;
    }
    if (this.by - r > h) {
      this.balls--;
      this.sparks.burst(this.bx, h - 2, 10, 220, EMBER, 0.5);
      if (this.balls <= 0) this.end(false);
      else this.serve();
    }
  }

  /** Is there a live brick at this point? If so, burst it. */
  private hitAt(x: number, y: number) {
    const c = Math.floor((x - this.ox) / this.bs), rr = Math.floor(y / this.bs);
    if (c < 0 || rr < 0 || c >= this.cols || rr >= this.rows) return false;
    const i = rr * this.cols + c;
    if (!this.alive[i]) return false;
    this.alive[i] = 0;
    this.left--;
    this.combo++;
    this.score += 10 + 5 * Math.min(this.combo - 1, 8);
    const cx = this.ox + (c + 0.5) * this.bs, cy = (rr + 0.5) * this.bs;
    this.sparks.burst(cx, cy, 5, 260, heatColor(0.6 + this.heat[i]! * 0.4), 0.6);
    for (let dy = -3; dy <= 3; dy++)
      for (let dx = -3; dx <= 3; dx++) {
        const nc = c + dx, nr = rr + dy;
        if (nc < 0 || nr < 0 || nc >= this.cols || nr >= this.rows) continue;
        const j = nr * this.cols + nc;
        if (this.alive[j]) this.heat[j] = Math.min(1, this.heat[j]! + 0.55 / (1 + Math.hypot(dx, dy)));
      }
    // A little faster as the wall thins.
    const sp = Math.hypot(this.vx, this.vy), want = this.speed * (1 + 0.45 * (1 - this.left / this.total));
    if (sp < want) {
      this.vx *= want / sp;
      this.vy *= want / sp;
    }
    if (this.left <= 0) this.end(true);
    return true;
  }

  private end(won: boolean) {
    this.state = won ? "won" : "lost";
    this.over = true;
    if (won) this.score += this.balls * 100;
    const best = this.record(this.score);
    this.ui.say(`${won ? "Gap closed. You reached across. Every dot." : "Out of balls."} Score ${this.score}.${best ? " A new best." : ""}`);
  }

  protected paint(ctx: CanvasRenderingContext2D) {
    const { ink, cols, rows, ox, c } = this;
    const dr = c * 0.47;
    for (let rr = 0; rr < rows; rr++)
      for (let cc = 0; cc < cols; cc++) {
        const i = rr * cols + cc;
        if (!this.alive[i]) continue;
        const col = heatColor(this.heat[i]!);
        for (let k = 0; k < 4; k++) {
          const dc = cc * 2 + (k & 1), dr2 = rr * 2 + (k >> 1);
          const v = dc < this.dcols ? this.ink1[dr2 * this.dcols + dc] : 0;
          if (v) ink.dot(col, ox + (dc + 0.5) * c, (dr2 + 0.5) * c, dr * (0.35 + 0.65 * v));
        }
      }
    this.sparks.draw(ink, c * 0.32);
    ink.flush(ctx);

    // The bar: a bone trackpad, rounded, with a faint seam.
    const x = this.px - this.pw / 2;
    ctx.fillStyle = BONE;
    ctx.beginPath();
    ctx.roundRect(x, this.py, this.pw, this.ph, this.ph / 2);
    ctx.fill();
    ctx.fillStyle = "rgba(10,10,10,0.35)";
    ctx.fillRect(x + this.pw * 0.2, this.py + this.ph * 0.42, this.pw * 0.6, 1);

    if (this.state === "lost" || this.state === "won") return;
    for (let i = this.trail.length - 1; i >= 1; i--) {
      ctx.fillStyle = `rgba(255,91,31,${(0.35 * (1 - i / this.trail.length)).toFixed(3)})`;
      ctx.beginPath();
      ctx.arc(this.trail[i]!.x, this.trail[i]!.y, this.r * (1 - i / 14), 0, TAU);
      ctx.fill();
    }
    const g = ctx.createRadialGradient(this.bx, this.by, 0, this.bx, this.by, this.r * 4);
    g.addColorStop(0, "rgba(255,91,31,0.45)");
    g.addColorStop(1, "rgba(255,91,31,0)");
    ctx.fillStyle = g;
    ctx.fillRect(this.bx - this.r * 4, this.by - this.r * 4, this.r * 8, this.r * 8);
    ctx.fillStyle = EMBER;
    ctx.beginPath();
    ctx.arc(this.bx, this.by, this.r, 0, TAU);
    ctx.fill();
  }

  protected status() {
    switch (this.state) {
      case "ready":
        return this.act("Tap to launch. Drag to move the bar.", "Space to launch. Arrows or the pointer move the bar.");
      case "won":
        return `Gap closed. You reached across. Every dot. ${this.act("Tap", "Space")} for another go.`;
      case "lost":
        return `Out of balls. ${this.act("Tap", "Space")} for another go.`;
      default:
        return null;
    }
  }

  protected hudText() {
    return `Score ${this.score} · Balls ${Math.max(0, this.balls)}${this.best !== null ? ` · Best ${this.best}` : ""}`;
  }

  protected release() {
    this.keys = { l: false, r: false };
    this.aim = null;
    this.down = null;
  }

  private action() {
    if (this.state === "ready") this.launch();
    else if (this.over) this.start();
  }

  protected onKey(k: string, down: boolean, repeat: boolean) {
    if (k === "ArrowLeft" || k === "a") return (this.keys.l = down), (this.aim = null), true;
    if (k === "ArrowRight" || k === "d") return (this.keys.r = down), (this.aim = null), true;
    if (isAction(k)) {
      if (down && !repeat) this.action();
      return true;
    }
    return k === "ArrowUp" || k === "ArrowDown";
  }

  protected onPointer(kind: PointerKind, p: Pt, e: PointerEvent) {
    if (kind === "move") {
      if (e.pointerType === "mouse" || this.down) this.aim = p.x;
      if (this.down && Math.hypot(p.x - this.down.x, p.y - this.down.y) > 10) this.down.moved = true;
    } else if (kind === "down") {
      this.down = { x: p.x, y: p.y, moved: false };
      if (e.pointerType === "mouse") this.action();
    } else if (kind === "up") {
      if (this.down && !this.down.moved && e.pointerType !== "mouse") this.action();
      this.down = null;
    } else this.down = null;
  }
}
