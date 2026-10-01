// Soft landing: the Mac pointer, tip down, has to settle on an ember pad among halftone hills and craters.
// Each landing leads to a steeper, thirstier level; a hard landing scatters the pointer into dots.

import { Game, isAction, type PointerKind, type Pt } from "./base";
import { BONE, clamp, EMBER, rand, Sparks, TAU } from "./kit";

/** The classic arrow pointer, tip at the origin, flipped so the tip points down (x right, y up = negative). */
const ARROW: [number, number][] = [[0, 0], [0, -17], [4, -13], [7, -20], [10, -19], [7, -12.5], [12, -12.5]];
type State = "ready" | "fly" | "landed" | "crashed";

export class Lander extends Game {
  readonly id = "lander" as const;
  readonly name = "Soft landing";
  readonly help = "Soft landing. Bring the pointer down tip first onto the ember pad, slowly. Up arrow or Space thrusts, left and right arrows steer, Escape leaves.";

  private state: State = "ready";
  private level = 1;
  private landed = 0;
  private ground: number[] = [];
  private pad = { x0: 0, x1: 0, y: 0 };
  private x = 0;
  private y = 0;
  private vx = 0;
  private vy = 0;
  private u = 1;
  private fuel = 100;
  private g = 100;
  private safe = 50;
  private keys = { up: false, l: false, r: false };
  private finger: Pt | null = null;
  private sparks = new Sparks(420, 300);

  protected reset() {
    this.level = 1;
    this.landed = 0;
    this.terrain();
  }

  protected live() {
    return this.state === "fly";
  }

  private terrain() {
    const { w, h, c, level } = this;
    this.u = clamp(h * 0.085, 16, 34) / 20;
    this.g = h * 0.16 * (1 + 0.1 * (level - 1));
    this.safe = h * 0.1;
    this.fuel = Math.max(40, 100 - 10 * (level - 1));
    this.sparks = new Sparks(420, h * 0.7);
    const n = Math.ceil(w / c) + 2;
    const amp = h * Math.min(0.2, 0.1 + 0.02 * level);
    const f1 = TAU / (n * rand(0.55, 0.9)), f2 = TAU / (n * rand(0.18, 0.3)), p1 = rand(0, TAU), p2 = rand(0, TAU);
    const gr: number[] = [];
    for (let i = 0; i < n; i++) gr.push(h * 0.74 - amp * (Math.sin(i * f1 + p1) * 0.65 + Math.sin(i * f2 + p2) * 0.35));
    // Craters: a dip with a small rim.
    for (let k = 0; k < 2 + Math.floor(Math.random() * 2); k++) {
      const ci = Math.floor(rand(0.05, 0.95) * n), rc = Math.floor(rand(2.5, 5)), depth = h * rand(0.03, 0.06);
      for (let i = Math.max(0, ci - rc - 1); i <= Math.min(n - 1, ci + rc + 1); i++) {
        const d = Math.abs(i - ci) / rc;
        gr[i] = gr[i]! + (d < 1 ? depth * (1 - d * d) : -depth * 0.3);
      }
    }
    for (let i = 0; i < n; i++) gr[i] = clamp(gr[i]!, h * 0.45, h * 0.95);
    const pw = Math.max(this.u * 22, w * Math.max(0.07, 0.16 - 0.018 * (level - 1)));
    const right = Math.random() < 0.5;
    const x0 = right ? rand(w * 0.55, w * 0.92 - pw) : rand(w * 0.08, w * 0.45 - pw);
    const i0 = Math.floor(x0 / c), i1 = Math.ceil((x0 + pw) / c);
    let sum = 0;
    for (let i = i0; i <= i1; i++) sum += gr[i]!;
    const py = sum / (i1 - i0 + 1);
    for (let i = i0; i <= i1; i++) gr[i] = py;
    this.ground = gr;
    this.pad = { x0: i0 * c, x1: i1 * c, y: py };
    // Start within reach of the pad: the push sideways and the fuel scale with the band's height, so on a wide
    // band a start at the far end would be out of range.
    const pc = (this.pad.x0 + this.pad.x1) / 2, reach = Math.min(w * 0.32, h * 1.3);
    const side = pc - reach * 0.55 < w * 0.05 ? 1 : pc + reach * 0.55 > w * 0.9 ? -1 : Math.random() < 0.5 ? -1 : 1;
    this.x = clamp(pc + side * rand(0.5, 1) * reach, w * 0.04, w * 0.9);
    this.y = this.u * 20 + 44 + h * 0.04;
    this.vx = rand(-1, 1) * h * 0.05;
    this.vy = 0;
    this.keys = { up: false, l: false, r: false };
    this.finger = null;
    this.state = "ready";
  }

  private groundAt(x: number) {
    const f = clamp(x / this.c, 0, this.ground.length - 1.001), i = Math.floor(f), t = f - i;
    return this.ground[i]! * (1 - t) + this.ground[i + 1]! * t;
  }

  protected tick(dt: number) {
    this.sparks.step(dt);
    if (this.state !== "fly") return;
    const { u, g } = this;
    let up = this.keys.up, l = this.keys.l, r = this.keys.r;
    if (this.finger) {
      up = true;
      const dx = this.finger.x - (this.x + 6 * u);
      l = dx < -u * 8;
      r = dx > u * 8;
    }
    if (this.fuel <= 0) up = l = r = false;
    let ax = 0, ay = g;
    if (up) {
      ay -= g * 2.2;
      this.fuel -= 18 * dt;
      for (let k = 0; k < 2; k++) this.sparks.puff(this.x + 3 * u, this.y + u, Math.PI / 2, this.h * 0.5, EMBER);
    }
    if (l) {
      ax -= g * 0.85;
      this.fuel -= 7 * dt;
      this.sparks.puff(this.x + 12 * u, this.y - 12 * u, 0, this.h * 0.35, EMBER, 0.25);
    }
    if (r) {
      ax += g * 0.85;
      this.fuel -= 7 * dt;
      this.sparks.puff(this.x, this.y - 12 * u, Math.PI, this.h * 0.35, EMBER, 0.25);
    }
    this.fuel = Math.max(0, this.fuel);
    this.vx += ax * dt;
    this.vy += ay * dt;
    this.x += this.vx * dt;
    this.y += this.vy * dt;
    if (this.x < 0) (this.x = 0), (this.vx = 0);
    if (this.x > this.w - 12 * u) (this.x = this.w - 12 * u), (this.vx = 0);
    // The ceiling sits under the score line.
    if (this.y < 20 * u + 36) (this.y = 20 * u + 36), (this.vy = Math.max(0, this.vy));

    const tipDown = this.y >= this.groundAt(this.x);
    const bodyDown = ARROW.some(([ax2, ay2]) => this.y + ay2 * u >= this.groundAt(this.x + ax2 * u) + 0.5 && ay2 !== 0);
    if (!tipDown && !bodyDown) return;
    const speed = Math.hypot(this.vx, this.vy);
    if (!bodyDown && this.x >= this.pad.x0 && this.x <= this.pad.x1 && speed <= this.safe) {
      this.state = "landed";
      this.y = this.pad.y;
      this.landed++;
      const best = this.record(this.landed);
      this.ui.say(`Touchdown. Gently. Level ${this.level} done.${best ? " A new best." : ""}`);
    } else {
      this.state = "crashed";
      this.over = true;
      for (const [px, py] of ARROW) this.sparks.burst(this.x + px * u, this.y + py * u, 6, this.h * 0.6, BONE, 0.9);
      this.sparks.burst(this.x, this.y, 10, this.h * 0.5, EMBER, 0.7);
      this.ui.say(`Hard landing. ${this.landed} ${this.landed === 1 ? "landing" : "landings"} this run.`);
    }
  }

  protected paint(ctx: CanvasRenderingContext2D) {
    const { ink, c, h } = this;
    // Halftone hills: big dots at the surface, smaller with depth.
    for (let x = c / 2; x < this.w; x += c) {
      const top = this.groundAt(x);
      for (let y = Math.ceil(top / c) * c + c / 2; y < h; y += c) {
        const depth = y - top;
        ink.dot("rgba(237,232,223,0.9)", x, y, Math.max(c * 0.1, c * 0.42 * (1 - depth / (h * 0.32))));
      }
    }
    for (let x = this.pad.x0 + c / 2; x < this.pad.x1; x += c) ink.dot(EMBER, x, this.pad.y - c * 0.1, c * 0.34);
    this.sparks.draw(ink, c * 0.3);
    ink.flush(ctx);
    if (this.state === "crashed") return;
    const u = this.u;
    ctx.beginPath();
    ARROW.forEach(([px, py], i) => (i ? ctx.lineTo(this.x + px * u, this.y + py * u) : ctx.moveTo(this.x + px * u, this.y + py * u)));
    ctx.closePath();
    ctx.fillStyle = BONE;
    ctx.fill();
    ctx.lineWidth = 1.5;
    ctx.strokeStyle = "#050505";
    ctx.stroke();
  }

  private speedNow() {
    return Math.round((Math.hypot(this.vx, this.vy) / this.h) * 100);
  }

  protected status() {
    const limit = Math.round((this.safe / this.h) * 100);
    switch (this.state) {
      case "ready":
        return this.act(
          `Touch and hold to thrust; the pointer drifts toward your finger. Land on the ember pad under speed ${limit}.`,
          `Hold Space or Up to thrust, Left and Right to steer. Land on the ember pad under speed ${limit}.`,
        );
      case "landed":
        return `Touchdown. Gently. ${this.act("Tap", "Space")} for level ${this.level + 1}.`;
      case "crashed":
        return `Hard landing. The dots will regroup. ${this.act("Tap", "Space")} to try again.`;
      default:
        return this.fuel <= 0 ? "Out of fuel. Gravity has it from here." : null;
    }
  }

  protected hudText() {
    return `Level ${this.level} · Fuel ${Math.round(this.fuel)}% · Speed ${this.speedNow()}${this.best !== null ? ` · Best ${this.best}` : ""}`;
  }

  protected release() {
    this.keys = { up: false, l: false, r: false };
    this.finger = null;
  }

  private action() {
    if (this.state === "landed") {
      this.level++;
      this.terrain();
    } else if (this.state === "crashed") this.start();
  }

  protected onKey(k: string, down: boolean, repeat: boolean) {
    const thrust = k === "ArrowUp" || k === "w" || k === " ";
    const left = k === "ArrowLeft" || k === "a", right = k === "ArrowRight" || k === "d";
    if (!thrust && !left && !right && !isAction(k)) return k === "ArrowDown";
    if (down && (this.state === "landed" || this.state === "crashed")) {
      if (!repeat && isAction(k)) this.action();
      return true;
    }
    if (down && this.state === "ready") this.state = "fly";
    if (thrust) this.keys.up = down;
    if (left) this.keys.l = down;
    if (right) this.keys.r = down;
    return true;
  }

  protected onPointer(kind: PointerKind, p: Pt) {
    if (kind === "down") {
      if (this.state === "landed" || this.state === "crashed") return this.action();
      if (this.state === "ready") this.state = "fly";
      this.finger = p;
    } else if (kind === "move") {
      if (this.finger) this.finger = p;
    } else this.finger = null;
  }
}
