// One switch for all ambient motion: the OS Reduce Motion setting, Save-Data, or the on-page pause button.

const KEY = "farside:motion";
const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
const listeners = new Set<() => void>();

function readPaused() {
  try {
    return window.localStorage.getItem(KEY) === "paused";
  } catch {
    return false;
  }
}

let paused = readPaused();

function saveData() {
  const c = (navigator as Navigator & { connection?: { saveData?: boolean } }).connection;
  return !!c?.saveData;
}

export const prefersReduced = () => mq.matches || saveData();
export const isPaused = () => paused;
export const motionAllowed = () => !prefersReduced() && !paused;

export function onMotionChange(fn: () => void) {
  listeners.add(fn);
}

export function setPaused(value: boolean) {
  paused = value;
  try {
    if (value) window.localStorage.setItem(KEY, "paused");
    else window.localStorage.removeItem(KEY);
  } catch {
    /* private mode: keep it for this page only */
  }
  document.documentElement.classList.toggle("motion-off", value);
  listeners.forEach((f) => f());
}

document.documentElement.classList.toggle("motion-off", paused);
mq.addEventListener("change", () => listeners.forEach((f) => f()));
