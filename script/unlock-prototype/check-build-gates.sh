#!/bin/bash
set -euo pipefail
rules=/Users/roshansilva/Documents/Codex/2026-10-01/testing
shopt -s nullglob
while :; do
    quiet=("$rules"/QUIET-GRANTED-*)
    if [[ ! -e "$rules/PAUSE-BUILDS" && ! -e "$rules/PRIORITY-BUILD" && ${#quiet[@]} -eq 0 ]]; then
        available_kb=$(df -Pk / | awk 'NR == 2 {print $4}')
        [[ "$available_kb" =~ ^[0-9]+$ && "$available_kb" -ge 10485760 ]] || { echo 'Build blocked: less than 10 GiB free on internal disk.'; exit 1; }
        exit 0
    fi
    echo 'Build paused by shared test gate; checking again in 60 seconds.'
    sleep 60
done
