import { frameFromQuery } from "./device";
import { Instance, type Variant } from "./stage";
import { lidVariant } from "./variants/lid";
import { orbitVariant } from "./variants/orbit";
import { pocketVariant } from "./variants/pocket";

const MAKERS: Record<string, () => Variant> = { lid: lidVariant, pocket: pocketVariant, orbit: orbitVariant };
const still = matchMedia("(prefers-reduced-motion: reduce)").matches || new URLSearchParams(location.search).has("still");
const spec = frameFromQuery();
const demos: Record<string, Instance> = {};

for (const fig of document.querySelectorAll<HTMLElement>(".lx[data-variant]")) {
  const id = fig.dataset.variant!;
  const make = MAKERS[id];
  if (make) demos[id] = new Instance(fig, make(), spec, still);
}

document.querySelectorAll<HTMLButtonElement>("[data-replay]").forEach((b) => {
  if (still) b.hidden = true;
  b.addEventListener("click", () => demos[b.dataset.replay!]?.replay());
});

const lab = document.querySelector<HTMLElement>("[data-lab]");
if (lab) {
  const tabs = [...lab.querySelectorAll<HTMLButtonElement>("[data-tab]")];
  const show = (id: string) => {
    if (!tabs.some((t) => t.dataset.tab === id)) id = "all";
    lab.dataset.view = id;
    for (const t of tabs) t.setAttribute("aria-selected", String(t.dataset.tab === id));
    if (id !== "all") demos[id]?.replay();
  };
  for (const t of tabs) {
    t.addEventListener("click", () => {
      show(t.dataset.tab!);
      history.replaceState(null, "", t.dataset.tab === "all" ? location.pathname + location.search : `#${t.dataset.tab}`);
    });
  }
  show(location.hash.slice(1) || "all");
}
