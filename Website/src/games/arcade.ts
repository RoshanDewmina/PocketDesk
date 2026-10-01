// The footer games: a game that borrows the footer's canvas, grid and loop (src/scripts/footer.ts) in the wordmark
// band. Loaded on demand, only after the footer's dot field starts.
//
// It starts by itself: once the page is scrolled to its end and the band is all in view, the wordmark becomes the
// game a beat later, and it waits (the wordmark comes back) whenever the band scrolls away. Until the visitor plays,
// nothing is taken from the page: the stage has no focus, the wheel and vertical swipes scroll, and only the left
// and right arrows (with nothing focused) and the pointer over the band steer. A click on the band, or a key while
// the stage has focus (Tab reaches it), hands the keys to the game; Escape, a press outside or tabbing away hands
// them back. Reduce Motion keeps the old opt-in: nothing moves until "Play anyway" is pressed.
// Everyone gets the game the footer carries in data-game (site.config.ts `look.footerGame`); on preview hosts
// (*.pages.dev, localhost) ?game=breakout|reach|lander|snake overrides it and a small switcher appears.

import type { Game, GameId, Ui } from "./base";
import { Breakout } from "./breakout";
import { Lander } from "./lander";
import { Reach } from "./reach";
import { Snake } from "./snake";
import type { Host } from "./types";

const GAMES: Record<GameId, new (host: Host, ui: Ui) => Game> = { breakout: Breakout, reach: Reach, lander: Lander, snake: Snake };
const NAMES: Record<GameId, string> = { breakout: "Breakout", reach: "Reach", lander: "Soft landing", snake: "Snake" };
const ORDER = Object.keys(GAMES) as GameId[];
const MIN = { w: 260, h: 150 };
/** ms between the band coming fully into view and the game taking it: the wordmark lands first. */
const BEAT = 600;

export function mountArcade(host: Host) {
  const mark = host.foot.querySelector<HTMLElement>(".foot-mark");
  if (mark && !mark.querySelector(".arc")) new Arcade(host, mark);
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls: string, parent: HTMLElement) {
  const e = document.createElement(tag);
  e.className = cls;
  parent.append(e);
  return e;
}

/** A text setter that leaves the DOM alone when nothing changed, and hides its node for null. */
function text(node: HTMLElement) {
  let cur: string | null | undefined;
  return (t: string | null) => {
    if (t === cur) return;
    cur = t;
    node.hidden = t === null;
    if (t !== null) node.textContent = t;
  };
}

const preview = () => /(^|\.)pages\.dev$|^localhost$|^127\.0\.0\.1$/.test(location.hostname);

class Arcade {
  private root: HTMLElement;
  private play: HTMLButtonElement;
  private lbl: HTMLElement;
  private gn: HTMLElement;
  private stage: HTMLElement;
  private help: HTMLElement;
  private picks: HTMLButtonElement[] = [];
  private ui: Ui;
  private id: GameId;
  private game: Game | null = null;
  /** The game has the canvas. */
  private running = false;
  /** The visitor is playing: keys and the wheel over the stage go to the game. */
  private engaged = false;
  private wakeT = 0;
  private helps: Partial<Record<GameId, Game>> = {};

  constructor(private host: Host, private mark: HTMLElement) {
    const q = preview() ? (new URLSearchParams(location.search).get("game") as GameId | null) : null;
    const set = host.foot.dataset.game as GameId | undefined;
    this.id = q && ORDER.includes(q) ? q : set && ORDER.includes(set) ? set : "breakout";

    const root = (this.root = el("div", "arc", mark));
    if (preview()) {
      const pick = el("div", "arc-pick", root);
      pick.setAttribute("role", "group");
      pick.setAttribute("aria-label", "Footer game (preview only)");
      for (const id of ORDER) {
        const b = el("button", "arc-pk plate", pick);
        b.type = "button";
        b.textContent = NAMES[id];
        b.addEventListener("click", () => this.pick(id));
        this.picks.push(b);
      }
    }
    this.play = el("button", "arc-play plate", root);
    this.play.type = "button";
    el("span", "arc-led", this.play).setAttribute("aria-hidden", "true");
    this.lbl = el("span", "arc-lbl", this.play);
    this.gn = el("span", "arc-gn", this.play);

    const stage = (this.stage = el("div", "arc-stage", root));
    stage.tabIndex = -1;
    stage.setAttribute("role", "application");
    stage.setAttribute("aria-roledescription", "game");
    const top = el("div", "arc-top", stage);
    const hud = el("p", "arc-hud plate", top);
    const cap = el("p", "arc-cap plate", top);
    const big = el("p", "arc-big", stage);
    big.setAttribute("aria-hidden", "true");
    const msg = el("p", "arc-msg plate", stage);
    this.help = el("p", "sr-only", root);
    this.help.id = "arc-help";
    stage.setAttribute("aria-describedby", "arc-help");
    this.play.setAttribute("aria-describedby", "arc-help");
    const live = el("p", "sr-only", root);
    live.setAttribute("aria-live", "polite");

    let sayT = 0;
    this.ui = {
      hud: text(hud),
      msg: text(msg),
      cap: text(cap),
      big: (n, unit) => {
        big.hidden = n === null;
        if (n === null) return;
        const u = document.createElement("span");
        u.className = "arc-unit";
        u.textContent = unit ?? "";
        big.replaceChildren(n, u);
      },
      say: (t) => {
        clearTimeout(sayT);
        live.textContent = "";
        sayT = window.setTimeout(() => (live.textContent = t), 60);
      },
    };
    this.ui.big(null);
    this.ui.cap(null);
    this.ui.msg(null);

    this.play.addEventListener("click", () => this.enter());
    this.listen();
    host.onMotionChange(() => {
      // Reduce Motion turned on: a game that started by itself stops; one the visitor is playing carries on.
      if (!this.auto() && this.running && !this.engaged) this.stop();
      this.render();
      this.wake();
    });
    host.onLayout(() => this.fit());
    // Scrolled away: the run waits and the wordmark comes back; at the end again it carries on.
    host.onAway(() => this.stop());
    host.onReveal(() => this.wake());
    // Another window took focus: key-ups won't arrive, so let go and pause; a self-started run picks up on return.
    window.addEventListener("blur", () => this.running && this.game?.suspend());
    window.addEventListener("focus", () => this.wake());
    document.addEventListener("visibilitychange", () => this.wake());
    this.fit();
    this.render();
    this.wake();
  }

  /** Motion allowed: the game starts by itself. Reduce Motion: only from the button. */
  private auto() {
    return this.host.motionAllowed();
  }

  /** Too small a band (a short window) gets no game at all. */
  private fit() {
    const b = this.host.geo().band;
    const ok = b.w >= MIN.w && b.h >= MIN.h;
    if (!ok) this.stop();
    this.root.hidden = !ok;
    if (ok) this.wake();
  }

  private render() {
    const g = this.game;
    this.play.hidden = this.running || this.auto();
    this.lbl.textContent = g && !g.over ? "Resume" : "Play anyway";
    this.gn.textContent = NAMES[this.id];
    this.help.textContent = (g ?? (this.helps[this.id] ??= new GAMES[this.id](this.host, this.ui))).help;
    this.picks.forEach((b, i) => b.setAttribute("aria-pressed", String(ORDER[i] === this.id)));
  }

  private pick(id: GameId) {
    if (id === this.id) return;
    this.stop();
    this.id = id;
    this.game = null;
    this.render();
    this.wake();
  }

  /** At the page end with motion allowed: start (a beat after arriving) or carry on. */
  private wake() {
    if (!this.auto() || this.root.hidden || document.hidden || !this.host.shown()) return;
    if (this.running) {
      if (!this.engaged && this.game?.paused) this.game.resume();
      return;
    }
    if (this.wakeT) return;
    this.wakeT = window.setTimeout(() => {
      this.wakeT = 0;
      if (this.auto() && !this.root.hidden && !this.running && this.host.shown()) this.run();
    }, BEAT);
  }

  /** Give the game the canvas: a fresh run, or the waiting one where it was. */
  private run() {
    let g = this.game;
    const fresh = !g || g.over || g.id !== this.id;
    if (fresh) g = this.game = new GAMES[this.id](this.host, this.ui);
    g!.auto = this.auto();
    this.running = true;
    this.host.foot.classList.add("arc-run");
    this.stage.tabIndex = 0;
    this.stage.setAttribute("aria-label", g!.name);
    this.stage.dataset.game = g!.id;
    if (fresh) g!.start();
    else {
      g!.layout();
      g!.resume();
    }
    this.host.setRunner(g!);
    this.render();
  }

  /** The Reduce Motion button: bring the band into view, run, and take the keys at once. */
  private enter() {
    // A footer that follows the page (no room to wait under it) may have the band partly off screen.
    // The fixed footer shows whole at the page end (and a band scrolled out of view stops the game).
    if (getComputedStyle(this.host.foot).position !== "fixed") this.mark.scrollIntoView({ block: "nearest", behavior: "instant" });
    else window.scrollTo({ top: document.documentElement.scrollHeight, behavior: "instant" });
    if (!this.running) this.run();
    this.engage();
  }

  private engage() {
    if (!this.running || this.engaged) return;
    this.engaged = true;
    this.host.foot.classList.add("arc-on");
    if (document.activeElement !== this.stage) this.stage.focus({ preventScroll: true });
  }

  /** Hand the keys back. A self-started run carries on; under Reduce Motion the run waits behind Resume. */
  private release(how: "esc" | "out" | "blur") {
    if (!this.engaged) return;
    this.engaged = false;
    this.host.foot.classList.remove("arc-on");
    if (this.auto()) {
      if (document.activeElement === this.stage) this.stage.blur();
      return;
    }
    this.stop();
    if (how === "esc") this.play.focus({ preventScroll: true });
  }

  /** The run waits (paused) and the wordmark comes back. */
  private stop() {
    clearTimeout(this.wakeT);
    this.wakeT = 0;
    if (!this.running) return;
    this.running = false;
    this.engaged = false;
    this.game?.suspend();
    this.host.setRunner(null);
    this.host.foot.classList.remove("arc-run", "arc-on");
    if (document.activeElement === this.stage) this.stage.blur();
    this.stage.tabIndex = -1;
    this.render();
  }

  private listen() {
    const { stage } = this;
    const at = (e: PointerEvent) => {
      const r = this.host.cv.getBoundingClientRect();
      return { x: e.clientX - r.left, y: e.clientY - r.top };
    };
    stage.addEventListener("keydown", (e) => {
      if (!this.running || !this.game || e.altKey || e.ctrlKey || e.metaKey || e.key === "Tab") return;
      if (e.key === "Escape") {
        if (!this.engaged) return;
        e.preventDefault();
        this.release("esc");
        return;
      }
      // A key on the focused stage is playing.
      this.engage();
      if (this.game.key(e, true)) e.preventDefault();
    });
    stage.addEventListener("keyup", (e) => {
      if (this.engaged && this.game?.key(e, false)) e.preventDefault();
    });
    // Not yet playing: left and right steer from anywhere nothing is focused. They don't scroll this page, and
    // up, down, Space and the page keys are left alone.
    const steer = (e: KeyboardEvent, down: boolean) => {
      if (!this.running || this.engaged || !this.game || e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
      if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
      const a = document.activeElement;
      if (a && a !== document.body && a !== document.documentElement) return;
      if (this.game.key(e, down)) e.preventDefault();
    };
    document.addEventListener("keydown", (e) => steer(e, true));
    document.addEventListener("keyup", (e) => steer(e, false));
    for (const type of ["pointerdown", "pointermove", "pointerup", "pointercancel"] as const) {
      stage.addEventListener(type, (e) => {
        if (!this.running || !this.game || !e.isPrimary) return;
        if (type === "pointerdown") {
          // A click is playing (keys too, from now on). A finger only steers, so the page still scrolls.
          if (e.pointerType === "mouse") this.engage();
          try {
            stage.setPointerCapture(e.pointerId);
          } catch {
            /* capture is a nicety */
          }
        }
        this.game.pointer(type.slice(7) as "down" | "move" | "up" | "cancel", at(e), e);
      });
    }
    stage.addEventListener("wheel", (e) => this.engaged && e.preventDefault(), { passive: false });
    stage.addEventListener("contextmenu", (e) => this.engaged && e.preventDefault());
    stage.addEventListener("focusout", (e) => {
      if (!this.engaged || !document.hasFocus()) return;
      if (!this.root.contains(e.relatedTarget as Node | null)) this.release("blur");
    });
    document.addEventListener(
      "pointerdown",
      (e) => {
        if (this.engaged && !this.root.contains(e.target as Node)) this.release("out");
      },
      true,
    );
  }
}
