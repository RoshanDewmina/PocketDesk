#!/bin/bash
# usage: run1.sh LABEL [ENV=VAL ...]
cd "$(dirname "$0")"
label=$1; shift
env LABEL=$label "$@" ./wrtcbench 2>/dev/null | grep -E "^\[|^t=|^SUMMARY|^SERIES|^refresh|^BGCHK|^LATENCY|^field|^setBwe|FAILED" | cut -c1-330
