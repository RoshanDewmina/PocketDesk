// Farside's Home screen (design/FARSIDE-DESIGN-SYSTEM.md, "Home"), drawn in iPhone points for the portrait
// screen (402 × 874). Positions below are shared with the scripts that tap it.

import { h, se, svg, use } from "./dom";

export const THUMB = { x: 40, y: 356, w: 136, h: 85, r: 8 };
export const PILL = { x: 190, y: 672 };
export const ARROW = { x: 346, y: 672 };

export type HomeRefs = { el: HTMLElement; pill: HTMLElement; arrow: HTMLElement; dot: HTMLElement; stat: HTMLElement; label: HTMLElement };

export function buildHome(): HomeRefs {
  const head = h("div", "hm-head", [svg("0 0 26 38", "hm-mk", [use("mk")]), h("b", "", ["farside"]), h("i", "hm-help", ["?"])]);
  const art = h("div", "hm-art", [h("i", "a"), h("i", "b"), h("span", "hm-gap")]);
  const cap = h("p", "hm-cap", ["Gap · across the room"]);
  const dot = h("i", "hm-dot");
  const stat = h("span", "", ["Ready · same Wi-Fi"]);
  const card = h("div", "hm-card", [
    h("div", "hm-thumb"),
    h("b", "hm-name", ["studio-mac"]),
    h("span", "hm-model", ["MacBook Pro · M4"]),
    h("p", "hm-stat", [dot, stat]),
    h("p", "hm-last", ["Last reached 11:48 PM · We won’t ask why"]),
  ]);
  const arrow = h("i", "hm-arrow", [
    svg("0 0 24 24", "", [se("path", { d: "M5 12h13M13 6l6 6-6 6", fill: "none", stroke: "currentColor", "stroke-width": 2.4, "stroke-linecap": "round", "stroke-linejoin": "round" })]),
  ]);
  const label = h("b", "", ["Connect"]);
  const pill = h("div", "hm-pill", [label, h("span", "", [" · Closes the gap"]), arrow]);
  const list = h("div", "hm-list", [h("p", "", ["Pair another Mac", h("i", "", ["›"])]), h("p", "", ["How to steer · 40 sec", h("i", "", ["›"])])]);
  const el = h("div", "lx-home", [head, art, cap, card, pill, list, h("p", "hm-foot", ["Free on this Wi-Fi"])]);
  return { el, pill, arrow, dot, stat, label };
}
