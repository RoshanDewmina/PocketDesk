// The footer games: a play button in the wordmark band, and a game that borrows the footer's canvas, grid and
// loop (src/scripts/footer.ts) once you ask for it. Loaded on demand, only after the footer's dot field starts.
//
// Opt-in only: nothing plays until the button is pressed. Keys reach a game only while its stage has focus;
// Escape, a press outside it or tabbing away leaves (the run waits, and the button offers Resume). Scrolling is
// held only inside the stage while playing. ?game=breakout|reach|lander|snake picks the game; preview hosts
// (*.pages.dev, localhost) also get a small switcher.

import type { Game, GameId, Ui } from "./base";
import { Breakout } from "./breakout";
import { coarse } from "./kit";
import { Lander } from "./lander";
import { Reach } from "./reach";
import { Snake } from "./snake";
import type { Host } from "./types";

const GAMES: Record<GameId, new (host: Host, ui: Ui) => Game> = { breakout: Breakout, reach: Reach, lander: Lander, snake: Snake };
const NAMES: Record<GameId, string> = { breakout: "Breakout", reach: "Reach", lander: "Soft landing", snake: "Snake" };
const ORDER = Object.keys(GAMES) as GameId[];
const MIN = { w: 260, h: 150 };

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
  private playing = false;
  private helps: Partial<Record<GameId, Game>> = {};

  constructor(private host: Host, private mark: HTMLElement) {
    const q = new URLSearchParams(location.search).get("game") as GameId | null;
    this.id = q && ORDER.includes(q) ? q : "breakout";

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
    host.onMotionChange(() => this.render());
    host.onLayout(() => this.fit());
    // Scrolled away: leave, so Space and the arrows scroll the page again; the run waits behind Resume.
    host.onAway(() => this.leave("out"));
    // Another window took focus: key-ups won't arrive, so let go and pause.
    window.addEventListener("blur", () => this.playing && this.game?.suspend());
    this.fit();
    this.render();
  }

  /** Too small a band (a short window) gets no game at all. */
  private fit() {
    const b = this.host.geo().band;
    const ok = b.w >= MIN.w && b.h >= MIN.h;
    if (!ok) this.leave("out");
    this.root.hidden = !ok;
  }

  private render() {
    const g = this.game;
    this.lbl.textContent = g && !g.over ? "Resume" : !this.host.motionAllowed() ? "Play anyway" : coarse() ? "Tap to play" : "Press to play";
    this.gn.textContent = NAMES[this.id];
    this.help.textContent = (g ?? (this.helps[this.id] ??= new GAMES[this.id](this.host, this.ui))).help;
    this.picks.forEach((b, i) => b.setAttribute("aria-pressed", String(ORDER[i] === this.id)));
  }

  private pick(id: GameId) {
    if (id === this.id) return;
    this.leave("out");
    this.id = id;
    this.game = null;
    this.render();
  }

  private enter() {
    let g = this.game;
    const fresh = !g || g.over || g.id !== this.id;
    if (fresh) g = this.game = new GAMES[this.id](this.host, this.ui);
    this.playing = true;
    this.host.foot.classList.add("arc-on");
    this.stage.tabIndex = 0;
    this.stage.setAttribute("aria-label", g!.name);
    this.stage.dataset.game = g!.id;
    // A footer that follows the page (no room to wait under it) may have the band partly off screen.
    // The fixed footer shows whole at the page end (and a band scrolled out of view leaves the game).
    if (getComputedStyle(this.host.foot).position !== "fixed") this.mark.scrollIntoView({ block: "nearest", behavior: "instant" });
    else window.scrollTo({ top: document.documentElement.scrollHeight, behavior: "instant" });
    if (fresh) g!.start();
    else {
      g!.layout();
      g!.resume();
    }
    this.host.setRunner(g!);
    this.stage.focus({ preventScroll: true });
    this.play.hidden = true;
  }

  private leave(how: "esc" | "out" | "blur") {
    if (!this.playing) return;
    this.playing = false;
    this.game?.suspend();
    this.host.setRunner(null);
    this.host.foot.classList.remove("arc-on");
    this.stage.tabIndex = -1;
    this.play.hidden = false;
    this.render();
    if (how === "esc") this.play.focus({ preventScroll: true });
  }

  private listen() {
    const { stage } = this;
    const at = (e: PointerEvent) => {
      const r = this.host.cv.getBoundingClientRect();
      return { x: e.clientX - r.left, y: e.clientY - r.top };
    };
    stage.addEventListener("keydown", (e) => {
      if (!this.playing || !this.game || e.altKey || e.ctrlKey || e.metaKey) return;
      if (e.key === "Escape") {
        e.preventDefault();
        this.leave("esc");
      } else if (e.key !== "Tab" && this.game.key(e, true)) e.preventDefault();
    });
    stage.addEventListener("keyup", (e) => {
      if (this.playing && this.game?.key(e, false)) e.preventDefault();
    });
    for (const type of ["pointerdown", "pointermove", "pointerup", "pointercancel"] as const) {
      stage.addEventListener(type, (e) => {
        if (!this.playing || !this.game || !e.isPrimary) return;
        if (type === "pointerdown") {
          try {
            stage.setPointerCapture(e.pointerId);
          } catch {
            /* capture is a nicety */
          }
        }
        this.game.pointer(type.slice(7) as "down" | "move" | "up" | "cancel", at(e), e);
      });
    }
    stage.addEventListener("wheel", (e) => this.playing && e.preventDefault(), { passive: false });
    stage.addEventListener("contextmenu", (e) => this.playing && e.preventDefault());
    stage.addEventListener("focusout", (e) => {
      if (!this.playing || !document.hasFocus()) return;
      if (!this.root.contains(e.relatedTarget as Node | null)) this.leave("blur");
    });
    document.addEventListener(
      "pointerdown",
      (e) => {
        if (this.playing && !this.root.contains(e.target as Node)) this.leave("out");
      },
      true,
    );
  }
}
