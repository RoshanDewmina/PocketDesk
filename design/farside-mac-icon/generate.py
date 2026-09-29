#!/usr/bin/env python3
"""Writes the Farside macOS app icon SVGs (FARSIDE-DESIGN-SYSTEM.md §6).

Void squircle on the macOS icon grid; a halftone fingertip reaching in from the upper left, a
crisp bone pointer from the lower right, and one ember dot where they meet. Smaller optical sizes
use fewer, larger dots and always keep the ember dot.

    python3 design/farside-mac-icon/generate.py    # writes the SVGs next to this file (NumPy)
    zsh design/farside-mac-icon/render.sh           # renders PNGs into the host asset catalog
"""
import math
from pathlib import Path

import numpy as np


HERE = Path(__file__).resolve().parent
VOID, BONE, EMBER = "#050505", "#EDE8DF", "#FF5B1F"
SIZE = 1024
# macOS icon grid: an 824 px body centred on the 1024 canvas.
BODY_X, BODY_Y, BODY_S, BODY_R = 100, 100, 824, 185.4
MEET = (512.0, 468.0)                  # fingertip meets pointer tip
FINGER_ANGLE = 0.72                    # radians; the finger points down and to the right
FINGER_WIDTH = 250
POINTER = [(0, 0), (0, 250), (60, 196), (98, 284), (134, 268), (96, 180), (176, 180)]


# ---------------------------------------------------------------- fingertip luminance field

def fingertip_field():
    """A close-up fingertip from the upper left: a shaded cylinder with a rounded end, a nail and
    two knuckle creases, touching the pointer tip. Values are bone luminance, 0 to 1."""
    ux, uy = math.cos(FINGER_ANGLE), math.sin(FINGER_ANGLE)          # toward the tip
    nx, ny = uy, -ux                                                  # toward the nail side
    tip_r = FINGER_WIDTH * 0.46
    cx, cy = MEET[0] - ux * (tip_r + 6), MEET[1] - uy * (tip_r + 6)   # centre of the rounded end
    ys, xs = np.mgrid[0:SIZE, 0:SIZE].astype(np.float64) + 0.5
    back = (cx - xs) * ux + (cy - ys) * uy                            # distance behind the tip centre
    side = (xs - cx) * nx + (ys - cy) * ny                            # + toward the nail
    half = tip_r + np.clip(back, 0, None) * 0.05                      # widens toward the hand
    inside = np.where(back >= 0, np.abs(side) <= half, np.hypot(xs - cx, ys - cy) <= tip_r)
    across = np.clip(side / np.maximum(half, 1), -1, 1)
    cylinder = np.sqrt(np.clip(1 - ((across - 0.2) / 1.2) ** 2, 0, 1))
    fade = np.clip(1 - back / 900, 0.3, 1)
    lum = np.where(inside, (0.12 + 0.88 * cylinder ** 1.4) * fade, 0.0)
    # the nail, lit, with a dark rim
    nail_u, nail_v = back + 30, side - half * 0.42
    nail = (np.abs(nail_u - 70) / 100) ** 2 + (np.abs(nail_v) / (half * 0.36)) ** 2
    lum = np.where(inside & (nail <= 1.0), 1.0, lum)
    lum = np.where(inside & (nail > 1.0) & (nail <= 1.8), lum * 0.12, lum)
    # knuckle creases
    for at in (300, 336):
        crease = inside & (np.abs(back - at - across * 18) < 9)
        lum = np.where(crease, lum * 0.2, lum)
    # a faint ground so the screen reads as halftone around the finger
    ground = np.clip(0.12 * (1 - np.hypot(xs - 420, ys - 360) / 620), 0, None)
    return np.maximum(lum, ground)


# ---------------------------------------------------------------- dots and SVG

def inside_body(x, y, margin):
    r = BODY_R
    cx = min(max(x, BODY_X + r), BODY_X + BODY_S - r)
    cy = min(max(y, BODY_Y + r), BODY_Y + BODY_S - r)
    return math.hypot(x - cx, y - cy) <= r - margin


def halftone_dots(field, pitch, floor=0.0, keep_clear=0.0):
    dots = []
    half = pitch / 2
    y = BODY_Y + half
    while y < BODY_Y + BODY_S:
        x = BODY_X + half
        while x < BODY_X + BODY_S:
            x0, x1 = int(max(0, x - half)), int(min(SIZE, x + half))
            y0, y1 = int(max(0, y - half)), int(min(SIZE, y + half))
            lum = float(field[y0:y1, x0:x1].mean())
            r = half * 1.04 * math.sqrt(min(lum, 1.0))
            clear = math.hypot(x - MEET[0], y - MEET[1]) < keep_clear
            if lum > floor and r >= pitch * 0.1 and not clear and inside_body(x, y, r + 8):
                dots.append((x, y, r))
            x += pitch
        y += pitch
    return dots


def pointer_path(scale, angle_deg=-4):
    a = math.radians(angle_deg)
    pts = [(MEET[0] + (x * math.cos(a) - y * math.sin(a)) * scale,
            MEET[1] + (x * math.sin(a) + y * math.cos(a)) * scale) for x, y in POINTER]
    return "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts) + " Z"


def svg(dots, pointer_scale, ember_r, glow_r, gap, shadow=True):
    circles = "\n      ".join(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}"/>' for x, y, r in dots)
    body = f'x="{BODY_X}" y="{BODY_Y}" width="{BODY_S}" height="{BODY_S}" rx="{BODY_R}" ry="{BODY_R}"'
    shadow_def = ('<filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">'
                  '<feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity="0.35"/></filter>'
                  if shadow else "")
    glow = f'<circle cx="{MEET[0]}" cy="{MEET[1]}" r="{glow_r}" fill="url(#glow)"/>' if glow_r else ""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">
  <defs>
    {shadow_def}
    <radialGradient id="ground" cx="0.42" cy="0.38" r="0.75">
      <stop offset="0" stop-color="#101010"/>
      <stop offset="1" stop-color="{VOID}"/>
    </radialGradient>
    <radialGradient id="glow">
      <stop offset="0" stop-color="{EMBER}" stop-opacity="0.6"/>
      <stop offset="0.4" stop-color="{EMBER}" stop-opacity="0.18"/>
      <stop offset="1" stop-color="{EMBER}" stop-opacity="0"/>
    </radialGradient>
    <clipPath id="body"><rect {body}/></clipPath>
  </defs>
  <rect {body} fill="url(#ground)"{' filter="url(#shadow)"' if shadow else ''}/>
  <g clip-path="url(#body)">
    <g fill="{BONE}">
      {circles}
    </g>
    {glow}
    <path d="{pointer_path(pointer_scale)}" fill="{BONE}" stroke="{VOID}" stroke-width="{gap}"
          stroke-linejoin="round" paint-order="stroke"/>
    <circle cx="{MEET[0]}" cy="{MEET[1]}" r="{ember_r}" fill="{EMBER}"/>
  </g>
  <rect x="{BODY_X + 1}" y="{BODY_Y + 1}" width="{BODY_S - 2}" height="{BODY_S - 2}" rx="{BODY_R - 1}" ry="{BODY_R - 1}"
        fill="none" stroke="{BONE}" stroke-opacity="0.1" stroke-width="2"/>
</svg>
'''


def mark_svg():
    rows = ["#", "##", "###", "####", "#####", "######", "###", "#.##", "...#"]
    dots = []
    for y, row in enumerate(rows):
        for x, cell in enumerate(row):
            if cell == "#":
                tip = x == 0 and y == 0
                dots.append(f'<circle cx="{2 + x * 2}" cy="{2 + y * 2}" r="{1.2 if tip else 0.84}" '
                            f'fill="{EMBER if tip else "#000"}"/>')
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="14" height="20" viewBox="0 0 14 20">\n  '
            + "\n  ".join(dots) + "\n</svg>\n")


def main():
    field = fingertip_field()
    variants = {
        # name: dots, pointer scale, ember radius, glow radius, gap around the pointer
        "farside-mac-icon": (halftone_dots(field, 20), 1.28, 30, 150, 16),
        "farside-mac-icon-256": (halftone_dots(field, 30), 1.3, 34, 150, 18),
        "farside-mac-icon-128": (halftone_dots(field, 50, floor=0.14, keep_clear=40), 1.38, 40, 130, 22),
        "farside-mac-icon-small": (halftone_dots(field, 104, floor=0.3, keep_clear=60), 1.48, 58, 110, 30),
        "farside-mac-icon-tiny": (halftone_dots(field, 150, floor=0.5, keep_clear=80), 1.6, 80, 0, 40),
    }
    for name, (dots, scale, ember, glow, gap) in variants.items():
        (HERE / f"{name}.svg").write_text(svg(dots, scale, ember, glow, gap, shadow=name != "farside-mac-icon-tiny"))
        print(f"{name}.svg: {len(dots)} dots")
    (HERE / "menubar-mark-live.svg").write_text(mark_svg())


if __name__ == "__main__":
    main()
