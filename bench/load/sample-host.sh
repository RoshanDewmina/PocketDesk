#!/bin/bash
# About-once-a-second host resource sampler (each row spans one 1 s top interval) for the realistic-load benchmark
# (Docs/perf/EFFICIENCY-AUDIT-2026-09-30.md §5). Writes a CSV beside the host's own stream
# statistics log so the two can be joined by wall-clock second.
#
#   sample-host.sh OUT.csv [SECONDS]
#
# Columns: time, load1, pressure (1 normal / 2 warn / 4 critical), swap_used_mb, compressed_mb,
# thermal (pmset CPU_Speed_Limit, 100 = none), host_cpu, host_power (top's energy-impact score),
# host_footprint_mb, host_threads, helper_cpu, helper_power. phys_footprint is read every 5 s
# (footprint is slower than top). Run powermetrics yourself with sudo for package watts:
#   sudo powermetrics --samplers cpu_power,gpu_power,thermal -i 1000 -o powermetrics.txt
set -euo pipefail

OUT="${1:?usage: sample-host.sh OUT.csv [SECONDS]}"
DURATION="${2:-120}"
HOST_PID=$(pgrep -x PocketDeskRemoteHost | head -1 || true)
HELPER_PID=$(pgrep -x FarsideWatchdog | head -1 || true)
[[ -n "$HOST_PID" ]] || { echo "PocketDeskRemoteHost is not running" >&2; exit 1; }

page=$(sysctl -n hw.pagesize)
footprint_mb=""
echo "time,load1,pressure,swap_used_mb,compressed_mb,thermal,host_cpu,host_power,host_footprint_mb,host_threads,helper_cpu,helper_power" > "$OUT"

top_fields() { # one 1 s top interval for both pids -> "hcpu hpower hthreads wcpu wpower"
  local args=(-pid "$HOST_PID")
  [[ -n "$HELPER_PID" ]] && args+=(-pid "$HELPER_PID")
  top -l 2 -s 1 "${args[@]}" -stats pid,cpu,power,th 2> /dev/null | awk -v h="$HOST_PID" -v w="${HELPER_PID:-0}" '
    $1 == h { hc = $2; hp = $3; ht = $4 } $1 == w { wc = $2; wp = $3 }
    END { print hc, hp, ht, wc, wp }'
}

for ((s = 0; s < DURATION; s++)); do
  t=$(date +%Y-%m-%dT%H:%M:%S)
  load1=$(sysctl -n vm.loadavg | awk '{print $2}')
  pressure=$(sysctl -n kern.memorystatus_vm_pressure_level)
  swap=$(sysctl -n vm.swapusage | awk '{for (i = 1; i <= NF; i++) if ($i == "used") { v = $(i + 2); sub(/M/, "", v); print v }}')
  compressed=$(vm_stat | awk -v pg="$page" '/occupied by compressor/ { gsub(/\./, "", $5); print int($5 * pg / 1048576) }')
  thermal=$(pmset -g therm 2> /dev/null | awk -F= '/CPU_Speed_Limit/ { gsub(/ /, "", $2); print $2 }')
  read -r hcpu hpower hthreads wcpu wpower <<< "$(top_fields)"
  if (( s % 5 == 0 )); then
    # First "Footprint:"/"phys_footprint:" figure, converted to MB (check the parse once by hand).
    footprint_mb=$(footprint -p "$HOST_PID" 2> /dev/null | awk '
      { for (i = 1; i < NF; i++) if ($i ~ /[Ff]ootprint:$/) {
          v = $(i + 1); u = $(i + 2)
          if (u ~ /^KB/) v /= 1024; else if (u ~ /^GB/) v *= 1024; else if (u ~ /^B/) v /= 1048576
          printf "%.1f\n", v; exit } }')
  fi
  echo "$t,$load1,$pressure,${swap:-},${compressed:-},${thermal:-100},${hcpu:-},${hpower:-},${footprint_mb:-},${hthreads:-},${wcpu:-},${wpower:-}" >> "$OUT"
done
echo "wrote $OUT ($DURATION s)"
