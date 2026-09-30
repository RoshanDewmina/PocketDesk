import type { Line, Pt, Rig } from "./rig";

export const CMD = 'agent "fix the pointer lag"';
export const prompt = (typed: string): Line => [["p", "~/app %"], ["", ` ${typed}`]];
export const OUT: Line[] = [
  [["p", "•"], ["", " Reading Pointer.swift, Camera.swift"]],
  [["p", "•"], ["", " Edited 3 files  "], ["n", "(+12 −4)"]],
  [["", "✓ committed “fixed from the couch”"]],
];
/** The terminal as A2 leaves it, for the variants that don't type into it. */
export const DONE: Line[] = [prompt(CMD), ...OUT, prompt("")];

/** Where the caret sits after `typed` on the first terminal line. */
export function promptEnd(r: Rig, typed: string): Pt {
  const t = r.rect(".x-term");
  return { x: t.x + 14 + 8.4 * (8 + typed.length) + 3, y: t.y + 28 + 10 + 11 };
}

/** Park the pointer somewhere and let the camera settle around it, no easing. */
export function park(r: Rig, P: Pt, z: number) {
  r.z = Math.max(z, r.minZ());
  r.P = { ...P };
  r.C = { x: P.x - r.vw / 2, y: P.y - r.vh / 2 };
  r.clampCam();
  r.settle();
}
