// Starts the home hero, variant 2 "From the pocket" from the hero lab. The stage markup (the Mac, its A2
// scene, the field canvases and the status line) is in the page; the phone is built here. The loop runs while
// motion is allowed and the hero is on screen; Reduce Motion, Save-Data or the pause button hold a still frame.

import { motionAllowed, onMotionChange } from "../scripts/motion";
import { pocketVariant } from "./pocket";
import { Instance } from "./stage";

export function startPocketHero(fig: HTMLElement) {
  const demo = new Instance(fig, pocketVariant());
  const sync = () => demo.setMotion(motionAllowed());
  onMotionChange(sync);
  sync();
  fig.classList.add("ready");
}
