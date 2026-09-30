#!/bin/bash
# Realistic-load generator for Farside host benchmarks (Docs/perf/EFFICIENCY-AUDIT-2026-09-30.md §5).
#
#   realistic-load.sh start <profile>   start one profile (loads add up; start several)
#   realistic-load.sh stop              stop everything this script started
#   realistic-load.sh status            list what is running
#
# Single loads:   cpu-bg N | cpu-fg N | ballast GIB | ballast-8gb | pressure warn|critical |
#                 gpu [ITERS] | vt | disk | apps
# Composites:     typical   = apps + gpu 32 + cpu-bg 2
#                 m1-8gb    = ballast-8gb + typical
#                 heavy     = m1-8gb + vt + disk + cpu-fg 2
#
# Refuses to run while /tmp/farside-quiet exists (a physical phone test is in progress).
# Nothing here needs sudo. Apps are opened, never quit: close them yourself after the run.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="${FARSIDE_LOAD_STATE:-${TMPDIR:-/tmp}/farside-load}"
REPO="$(cd "$HERE/../.." && pwd)"
mkdir -p "$STATE"

guard() {
  if [[ -e /tmp/farside-quiet ]]; then
    echo "realistic-load: /tmp/farside-quiet exists; a phone test is running. Not starting load." >&2
    exit 2
  fi
}

remember() { echo "$1 $2" >> "$STATE/pids"; }

cpu() { # $1 = count, $2 = "bg" (background QoS, E-cores first) or "fg"
  local n="$1" i
  for ((i = 0; i < n; i++)); do
    if [[ "$2" == bg ]]; then taskpolicy -b yes > /dev/null & else yes > /dev/null & fi
    remember $! "cpu-$2"
  done
}

ballast() {
  python3 "$HERE/ballast.py" --gib "$1" > "$STATE/ballast.log" 2>&1 &
  remember $! "ballast-$1GiB"
  echo "ballast: allocating $1 GiB (see $STATE/ballast.log)"
}

ballast_8gb() { # leave the RAM of an 8 GB Mac: total − 8 GiB
  local total
  total=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  if (( total <= 8 )); then echo "already ≤ 8 GiB; no ballast"; return; fi
  ballast $(( total - 8 ))
}

pressure() {
  memory_pressure -l "$1" > "$STATE/pressure.log" 2>&1 &
  remember $! "memory_pressure-$1"
}

gpu() { # a steady WebGL load in Safari, the browser a typical user has open
  open -a Safari "file://$HERE/gpu-load.html?iters=${1:-64}"
  echo "gpu: Safari tab open (close it after the run)"
}

vt() { # a second VideoToolbox encoder, like a FaceTime or Zoom call running beside Farside
  ffmpeg -hide_banner -loglevel error -re -f lavfi -i testsrc2=s=1920x1080:r=30 \
    -c:v h264_videotoolbox -realtime 1 -b:v 3M -f null - > "$STATE/vt.log" 2>&1 &
  remember $! "vt-encode"
}

disk() { # steady write + read of a 2 GiB file, like a sync client or Spotlight catching up
  ( while true; do
      dd if=/dev/urandom of="$STATE/disk.bin" bs=1m count=2048 2> /dev/null
      dd if="$STATE/disk.bin" of=/dev/null bs=1m 2> /dev/null
    done ) &
  remember $! "disk"
}

apps() { # the "some apps open" set; each is opened if installed
  local tabs=(https://www.apple.com https://en.wikipedia.org/wiki/Special:Random https://github.com/stasel/WebRTC
              https://developer.apple.com/documentation/screencapturekit https://news.ycombinator.com)
  open -a Safari "${tabs[@]}" || true
  for app in Slack Cursor Notion WhatsApp; do open -ga "$app" 2> /dev/null && echo "opened $app" || true; done
  open -ga Xcode "$REPO/PocketDesktop.xcodeproj" 2> /dev/null && echo "opened Xcode (idle project)" || true
  open -ga Music 2> /dev/null || true
  echo "apps: start playback in Music yourself if you want audio in the mix"
}

start() {
  guard
  case "$1" in
    cpu-bg) cpu "${2:?count}" bg ;;
    cpu-fg) cpu "${2:?count}" fg ;;
    ballast) ballast "${2:?GiB}" ;;
    ballast-8gb) ballast_8gb ;;
    pressure) pressure "${2:?warn|critical}" ;;
    gpu) gpu "${2:-64}" ;;
    vt) vt ;;
    disk) disk ;;
    apps) apps ;;
    typical) apps; gpu 32; cpu 2 bg ;;
    m1-8gb) ballast_8gb; apps; gpu 32; cpu 2 bg ;;
    heavy) ballast_8gb; apps; gpu 32; cpu 2 bg; vt; disk; cpu 2 fg ;;
    *) echo "unknown profile $1" >&2; exit 64 ;;
  esac
}

stop() {
  [[ -f "$STATE/pids" ]] || { echo "nothing running"; return; }
  while read -r pid label; do
    pkill -TERM -P "$pid" 2> /dev/null || true
    kill -TERM "$pid" 2> /dev/null && echo "stopped $label ($pid)" || true
  done < "$STATE/pids"
  rm -f "$STATE/pids" "$STATE/disk.bin"
  echo "Safari tabs and apps opened by 'apps'/'gpu' are left open; close them yourself."
}

status() {
  [[ -f "$STATE/pids" ]] || { echo "nothing running"; return; }
  while read -r pid label; do
    if kill -0 "$pid" 2> /dev/null; then echo "running $label ($pid)"; else echo "exited  $label ($pid)"; fi
  done < "$STATE/pids"
  echo "memory pressure level: $(sysctl -n kern.memorystatus_vm_pressure_level) (1 normal, 2 warn, 4 critical)"
  sysctl -n vm.swapusage
}

case "${1:-}" in
  start) shift; start "$@" ;;
  stop) stop ;;
  status) status ;;
  *) sed -n '2,17p' "$0"; exit 64 ;;
esac
