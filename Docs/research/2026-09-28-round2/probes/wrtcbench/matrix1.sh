#!/bin/bash
cd "$(dirname "$0")"
OUT=matrix1.txt; : > $OUT
run() { echo "### $*" >> $OUT; ./run1.sh "$@" | grep -E "^SUMMARY|^BGCHK|^LATENCY|^setBwe|^field|FAILED" >> $OUT; }
for res in "1920 1248" "2940 1912"; do
  set -- $res; W=$1; H=$2
  run "base-${W}" W=$W H=$H SECONDS=16
  run "bwe12M-${W}" W=$W H=$H SECONDS=16 BWE_START=12000000
  run "playout0-${W}" W=$W H=$H SECONDS=16 "TRIALS=WebRTC-ForcePlayoutDelay=min_ms:0,max_ms:0;WebRTC-ForceSendPlayoutDelay=min_ms:0,max_ms:0"
  run "pace30-${W}" W=$W H=$H SECONDS=16 "TRIALS=WebRTC-Video-Pacing=factor:2.5,max_delay:30ms"
  run "bwe12M+playout0+pace30-${W}" W=$W H=$H SECONDS=16 BWE_START=12000000 "TRIALS=WebRTC-ForcePlayoutDelay=min_ms:0,max_ms:0;WebRTC-ForceSendPlayoutDelay=min_ms:0,max_ms:0;WebRTC-Video-Pacing=factor:2.5,max_delay:30ms"
done
echo "### DONE" >> $OUT
