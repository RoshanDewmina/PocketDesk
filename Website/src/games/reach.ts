// Reach: five rounds of "press when the dot leaves". The ember dot waits at the start of the wordmark, leaves
// at a random moment and runs across it; the time from leaving to your press is your reach for that round.

import { Game, isAction, type PointerKind, type Pt } from "./base";
import { clamp, EMBER, heatColor, rand, TAU, wordCells } from "./kit";

const ROUNDS = 5;
const CAPTION = "Your reach, measured in this tab; Farside’s job is the trip to your Mac.";
type State = "intro" | "wait" | "go" | "shown" | "early" | "slow" | "done";

function verdict(avg: number) {
  if (avg < 200) return "Faster than your Wi‑Fi. Barely.";
  if (avg < 250) return "Quick. The dot noticed.";
  if (avg < 320) return "Respectable. Your Mac would wait for that.";
  if (avg < 420) return "Unhurried. The dot is patient.";
  return "The dot waited. It is used to that.";
}

export class Reach extends Game {
  readonly id = "reach" as const;
  readonly name = "Reach";
  readonly help = "Reach. Five rounds: press Space or tap the moment the ember dot leaves. Pressing early restarts the round. Escape leaves.";
  protected lowerIsBetter = true;

  private state: State = "intro";
  private times: number[] = [];
  private waitFor = 0;
  private waited = 0;
  private goAt = 0;
  private since = 0;
  private cols = 0;
  private rows = 0;
  private cov = new Float32Array(0);
  private run = 0;
  private start0 = { x: 0, y: 0 };
  private end0 = 0;

  protected reset() {
    const { w, h, c } = this;
    const g = wordCells(w, h, c, { x: w * 0.06, y: h * 0.12, w: w * 0.88, h: h * 0.62 });
    this.cols = g.cols;
    this.rows = g.rows;
    this.cov = g.cov;
    let x0 = g.cols, x1 = 0;
    for (let i = 0; i < g.cov.length; i++) if (g.cov[i]! > 0.3) (x0 = Math.min(x0, i % g.cols)), (x1 = Math.max(x1, i % g.cols));
    this.start0 = { x: Math.max(c, (x0 - 2) * c), y: h * 0.43 };
    this.end0 = Math.min(w - c, (x1 + 2) * c);
    this.times = [];
    this.state = "intro";
    this.ui.cap(CAPTION);
    this.ui.big(null);
  }

  protected live() {
    return this.state === "wait" || this.state === "go";
  }

  suspend() {
    // A paused round can't be timed fairly: put it back to waiting.
    if (this.state === "go") this.state = "wait";
    if (this.state === "wait") this.waited = 0;
    super.suspend();
  }

  private next() {
    this.state = "wait";
    this.waitFor = rand(1.4, 3.8);
    this.waited = 0;
    this.run = 0;
    this.ui.big(null);
  }

  protected tick(dt: number) {
    this.since += dt;
    if (this.state === "wait") {
      this.waited += dt;
      if (this.waited >= this.waitFor) {
        this.state = "go";
        this.goAt = performance.now();
        this.run = 0;
      }
    } else if (this.state === "go") {
      this.run += dt;
      if (performance.now() - this.goAt > 2500) {
        this.state = "slow";
        this.ui.say("The dot got away.");
      }
    } else if (this.state === "shown" && this.since > 1.3) {
      if (this.times.length >= ROUNDS) this.finish();
      else this.next();
    }
  }

  private press(at: number) {
    switch (this.state) {
      case "intro":
      case "early":
      case "slow":
        this.next();
        return;
      case "wait":
        this.state = "early";
        this.ui.say("Too soon. The dot hadn't left yet.");
        return;
      case "go": {
        const ms = clamp(at - this.goAt, 0, 9999);
        this.times.push(ms);
        this.state = "shown";
        this.since = 0;
        this.ui.big(String(Math.round(ms)), "ms");
        this.ui.say(`${Math.round(ms)} milliseconds.`);
        return;
      }
      case "shown":
        if (this.times.length >= ROUNDS) this.finish();
        else this.next();
        return;
      case "done":
        this.start();
    }
  }

  private finish() {
    this.state = "done";
    this.over = true;
    const avg = this.times.reduce((a, b) => a + b, 0) / this.times.length;
    const best = this.record(avg);
    this.ui.big(String(Math.round(avg)), "ms");
    this.ui.say(`Average ${Math.round(avg)} milliseconds, quickest ${Math.round(Math.min(...this.times))}. ${verdict(avg)}${best ? " A new best." : ""}`);
  }

  protected paint(ctx: CanvasRenderingContext2D) {
    const { ink, c, cols, rows, cov } = this;
    const going = this.state === "go" || this.state === "shown";
    const dotX = this.state === "go" ? this.start0.x + (this.end0 - this.start0.x) * clamp(this.run / 0.45, 0, 1) : this.state === "shown" ? this.end0 : this.start0.x;
    for (let r = 0; r < rows; r++)
      for (let cc = 0; cc < cols; cc++) {
        const v = cov[r * cols + cc]!;
        if (v <= 0.3) continue;
        const x = (cc + 0.5) * c, y = (r + 0.5) * c;
        // Dots the leaving ember has passed glow, then cool.
        const heat = going && x < dotX ? clamp(1 - (dotX - x) / (this.w * 0.5), 0, 1) * 0.8 : 0;
        ink.dot(heat > 0.05 ? heatColor(heat) : "rgba(237,232,223,0.42)", x, y, c * 0.44 * (0.4 + 0.6 * v));
      }
    ink.flush(ctx);
    const pulse = this.state === "wait" ? 1 + 0.12 * Math.sin(performance.now() / 260) : 1;
    const r = c * 0.75 * pulse;
    const y = this.start0.y;
    const g = ctx.createRadialGradient(dotX, y, 0, dotX, y, r * 5);
    g.addColorStop(0, "rgba(255,91,31,0.5)");
    g.addColorStop(1, "rgba(255,91,31,0)");
    ctx.fillStyle = g;
    ctx.fillRect(dotX - r * 5, y - r * 5, r * 10, r * 10);
    ctx.fillStyle = EMBER;
    ctx.beginPath();
    ctx.arc(dotX, y, r, 0, TAU);
    ctx.fill();
  }

  protected status() {
    const go = this.act("tap", "press Space");
    switch (this.state) {
      case "intro":
        return `Five rounds. When the dot leaves, ${go}. ${this.act("Tap", "Space")} to begin.`;
      case "wait":
        return "Wait for it.";
      case "go":
        return "Now.";
      case "early":
        return `Too soon. The dot hadn't left yet. ${this.act("Tap", "Space")} to try again.`;
      case "slow":
        return `The dot got away. ${this.act("Tap", "Space")} to try again.`;
      case "shown":
        return `Round ${this.times.length} of ${ROUNDS}.`;
      case "done": {
        const avg = this.times.reduce((a, b) => a + b, 0) / this.times.length;
        return `Average ${Math.round(avg)} ms, quickest ${Math.round(Math.min(...this.times))} ms. ${verdict(avg)} ${this.act("Tap", "Space")} for another go.`;
      }
    }
  }

  protected hudText() {
    const round = Math.min(ROUNDS, this.times.length + (this.state === "done" || this.state === "shown" ? 0 : 1));
    return `Round ${round} of ${ROUNDS}${this.best !== null ? ` · Best ${this.best} ms` : ""}`;
  }

  protected onKey(k: string, down: boolean, repeat: boolean, at: number) {
    if (!isAction(k)) return k.startsWith("Arrow");
    if (down && !repeat) this.press(at);
    return true;
  }

  protected onPointer(kind: PointerKind, _p: Pt, e: PointerEvent) {
    if (kind === "down") this.press(e.timeStamp || performance.now());
  }
}
