// The contract between the footer's dot field (src/scripts/footer.ts) and the lazily loaded games
// (src/games/arcade.ts). Type-only, so neither bundle pulls in the other's code.

export type Rect = { x: number; y: number; w: number; h: number };

/** The footer canvas as the field lays it out, in CSS pixels. */
export type Geo = {
  W: number;
  H: number;
  /** Dot pitch of the field grid (7, 9 or 11 px). */
  step: number;
  /** The wordmark band (.foot-mark), relative to the canvas. */
  band: Rect;
};

/** A running game: the field hands it its frames while it is set. */
export interface Runner {
  step(dtMs: number): void;
  draw(ctx: CanvasRenderingContext2D): void;
  /** The loop stopped (footer covered, tab hidden): freeze and say so. */
  suspend(): void;
  /** The field relaid out (resize, rotation). Progress must survive this. */
  layout(): void;
}

export interface Host {
  foot: HTMLElement;
  cv: HTMLCanvasElement;
  geo(): Geo;
  motionAllowed(): boolean;
  onMotionChange(fn: () => void): void;
  /** Route the loop to a game (or back to the wordmark with null). */
  setRunner(r: Runner | null): void;
  /** After the field relays out (resize, rotation), with the new band. */
  onLayout(fn: () => void): void;
  /** The band scrolled out of view while a game was running. */
  onAway(fn: () => void): void;
  /** Is the page scrolled to its end with the band all in view? */
  shown(): boolean;
  /** After every scroll or resize while some of the footer shows. */
  onReveal(fn: () => void): void;
  /** Draw the field's background grain (the faint dots) across the canvas. */
  grain(ctx: CanvasRenderingContext2D): void;
}

export type ArcadeModule = { mountArcade(host: Host): void };
