"""Generate the Farside app icon SVG: void ground, halftone fingertip (upper left),
crisp pointer (lower right), ember dot where they meet."""
import math
import sys

SIZE = 1024
VOID = "#050505"
BONE = "#EDE8DF"
EMBER = "#FF5B1F"

pitch = float(sys.argv[1]) if len(sys.argv) > 1 else 50.0
out = sys.argv[2] if len(sys.argv) > 2 else "farside-icon.svg"

# Meeting point and approach direction (finger points down-right toward it).
M = (520.0, 486.0)
angle = math.radians(30)
d = (math.cos(angle), math.sin(angle))
n = (-d[1], d[0])  # left-hand normal in screen space (points down-left)
finger_tip = (M[0] - 70 * d[0], M[1] - 70 * d[1])


def to_local(p):
    """Screen point -> hand frame: +x along the finger toward the tip, origin at the fingertip."""
    x, y = p[0] - finger_tip[0], p[1] - finger_tip[1]
    return (x * d[0] + y * d[1], x * n[0] + y * n[1])


def seg_dist(p, a, b):
    ax, ay = a; bx, by = b; px, py = p
    abx, aby = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * abx + (py - ay) * aby) / (abx * abx + aby * aby)))
    cx, cy = ax + abx * t, ay + aby * t
    return math.hypot(px - cx, py - cy)


def ellipse_inside(p, c, rx, ry):
    return ((p[0] - c[0]) / rx) ** 2 + ((p[1] - c[1]) / ry) ** 2


def smooth_edge(dist, radius, soft=22.0):
    """1 inside, fading to 0 across a soft band at the edge."""
    return max(0.0, min(1.0, (radius - dist) / soft + 0.5))


def hand_light(p):
    lx, ly = to_local(p)
    # Index finger: tapered, round tip, brightest at the tip.
    t = min(1.0, max(0.0, -lx / 640.0))
    radius = 60 + 28 * t
    body = smooth_edge(seg_dist((lx, ly), (-760, 10), (-radius * 0.95, 0)), radius, 16)
    light = body * (1.0 - 0.4 * t)
    # Fingernail: a dark bed with a bright rim, on top of the tip.
    nail = ellipse_inside((lx, ly), (-92, -22), 62, 32)
    if nail < 1:
        light *= 0.12 + 0.88 * min(1.0, max(0.0, (nail - 0.5) / 0.5))
    # Knuckle creases.
    for cx in (-250, -450):
        band = abs(lx - cx)
        if band < 12 and ly > -radius * 0.7:
            light *= 0.25 + 0.75 * band / 12
    # Curled fingers under the index finger, separated by dark gaps.
    for (a, b, r, g) in [((-560, 150), (-420, 170), 60, 0.66), ((-600, 290), (-470, 308), 58, 0.54),
                         ((-650, 420), (-540, 436), 52, 0.44)]:
        dist = seg_dist((lx, ly), a, b)
        if dist < r + 14:
            light = light * max(0.0, min(1.0, (dist - r) / 14)) if dist > r else light
        light = max(light, smooth_edge(dist, r - 8, 14) * g)
    back = ellipse_inside((lx, ly), (-880, 240), 260, 300)
    light = max(light, max(0.0, min(1.0, (1 - back) * 2.0)) * 0.36)
    return light


def ember_light(p):
    r = math.hypot(p[0] - M[0], p[1] - M[1])
    return max(0.0, 1.0 - r / 92.0) ** 1.4


def ambient(p):
    r = math.hypot(p[0] - M[0], p[1] - M[1])
    return 0.0


# Crisp macOS-style arrow, tip slightly past the meeting point.
ARROW = [(0, 0), (0, 250), (60, 196), (98, 284), (134, 268), (96, 180), (176, 180)]
arrow_scale = 1.5
arrow_tip = (M[0] + 20, M[1] + 18)
arrow_pts = [(arrow_tip[0] + x * arrow_scale, arrow_tip[1] + y * arrow_scale) for x, y in ARROW]


def inside_poly(p, poly):
    x, y = p
    inside = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]; xj, yj = poly[j]
        if ((yi > y) != (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi + 1e-9) + xi):
            inside = not inside
        j = i
    return inside


def near_arrow(p, margin):
    if inside_poly(p, arrow_pts):
        return True
    for i in range(len(arrow_pts)):
        if seg_dist(p, arrow_pts[i], arrow_pts[(i + 1) % len(arrow_pts)]) < margin:
            return True
    return False


dots = []
cells = int(math.ceil(SIZE / pitch))
offset = (SIZE - cells * pitch) / 2
max_r = pitch * 0.5 * 1.04
for j in range(cells):
    for i in range(cells):
        cx = offset + (i + 0.5) * pitch
        cy = offset + (j + 0.5) * pitch
        p = (cx, cy)
        if near_arrow(p, pitch * 0.62):
            continue
        light = max(hand_light(p), ambient(p))
        glow = ember_light(p)
        level = max(light, glow * 0.7)
        r = max_r * math.sqrt(min(1.0, level))
        if r < pitch * 0.07:
            continue
        colour = EMBER if glow > 0.45 else ("#F7A57F" if glow > 0.2 else BONE)
        dots.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{colour}"/>')

arrow_path = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in arrow_pts) + " Z"
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">
  <defs>
    <radialGradient id="glow" cx="{M[0]}" cy="{M[1]}" r="210" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{EMBER}" stop-opacity="0.55"/>
      <stop offset="0.45" stop-color="{EMBER}" stop-opacity="0.16"/>
      <stop offset="1" stop-color="{EMBER}" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="{SIZE}" height="{SIZE}" fill="{VOID}"/>
  <circle cx="{M[0]}" cy="{M[1]}" r="210" fill="url(#glow)"/>
  <g>{''.join(dots)}</g>
  <path d="{arrow_path}" fill="{BONE}" stroke="{VOID}" stroke-width="22" stroke-linejoin="round" paint-order="stroke"/>
  <path d="{arrow_path}" fill="{BONE}"/>
  <circle cx="{M[0]}" cy="{M[1]}" r="52" fill="{VOID}"/>
  <circle cx="{M[0]}" cy="{M[1]}" r="38" fill="{EMBER}"/>
</svg>
'''
open(out, "w").write(svg)
print(out, len(dots), "dots")
