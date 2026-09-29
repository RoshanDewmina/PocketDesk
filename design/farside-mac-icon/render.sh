#!/bin/zsh
# Renders the icon SVGs with headless Chrome and writes the macOS AppIcon sizes into the host's
# asset catalog. Needs Google Chrome and Python 3 with Pillow. Usage: render.sh [review-png]
set -euo pipefail
here="${0:A:h}"
repo="${here:h:h}"
chrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 "$here/generate.py"
# Headless Chrome may linger after a screenshot; give each render 30 s, then stop it.
shoot() {
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size=1024,1024 --virtual-time-budget=2000 \
    --user-data-dir="$work/profile" --screenshot="$2" "file://$1" > /dev/null 2>&1 &
  local pid=$!
  for attempt in {1..60}; do
    kill -0 $pid 2>/dev/null || break
    sleep 0.5
  done
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  [[ -s "$2" ]] || { print -u2 "Chrome did not render $1"; return 1; }
}
for name in farside-mac-icon farside-mac-icon-256 farside-mac-icon-128 farside-mac-icon-small farside-mac-icon-tiny; do
  shoot "$here/$name.svg" "$work/$name.png"
done

python3 - "$work" "$repo/RemoteHost/Assets.xcassets/AppIcon.appiconset" "${1:-}" <<'PY'
import json, sys
from pathlib import Path
from PIL import Image

work, out, review = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
out.mkdir(parents=True, exist_ok=True)
source = {16: "farside-mac-icon-tiny", 32: "farside-mac-icon-small", 64: "farside-mac-icon-small",
          128: "farside-mac-icon-128", 256: "farside-mac-icon-256", 512: "farside-mac-icon", 1024: "farside-mac-icon"}
images = []
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = points * scale
        name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
        art = Image.open(work / f"{source[pixels]}.png").convert("RGBA")
        art.resize((pixels, pixels), Image.LANCZOS).save(out / name)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
(out / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
(out.parent / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

if review:
    # Each shipped image at its own pixel size (1024 shown at 256), on a dark and a light ground.
    files = ["icon_512x512@2x.png", "icon_128x128@2x.png", "icon_128x128.png",
             "icon_32x32@2x.png", "icon_32x32.png", "icon_16x16.png"]
    sheet = Image.new("RGBA", (1000, 640), (5, 5, 5, 255))
    sheet.paste(Image.new("RGBA", (1000, 320), (236, 236, 236, 255)), (0, 320))
    x = 32
    for name in files:
        art = Image.open(out / name).convert("RGBA")
        shown = min(art.width, 256)
        art = art.resize((shown, shown), Image.LANCZOS)
        for top in (32, 352):
            sheet.alpha_composite(art, (x, top + (256 - shown) // 2))
        x += shown + 32
    sheet.save(review)
    print(f"review sheet: {review}")
print(f"wrote {len(images)} icon images to {out}")
PY
