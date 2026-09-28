#!/bin/bash
cd "$(dirname "$0")"
OUT=matrix2.txt; : > $OUT
waitquiet() { for i in $(seq 1 450); do l=$(sysctl -n vm.loadavg | awk "{print \$2}"); if (( $(echo "$l < 14" | bc -l) )); then return; fi; sleep 2; done; }
run() { waitquiet; echo "### load=$(sysctl -n vm.loadavg | awk '{print $2}') $*" >> $OUT; ./run1.sh "$@" | grep -E "^SUMMARY|^SERIES|^refresh|^LATENCY|FAILED" >> $OUT; }
PLAY="WebRTC-ForcePlayoutDelay=min_ms:0,max_ms:0;WebRTC-ForceSendPlayoutDelay=min_ms:0,max_ms:0"
for rep in 1 2 3; do
  run "base#$rep" W=1920 H=1248 SECONDS=16
  run "playout0#$rep" W=1920 H=1248 SECONDS=16 "TRIALS=$PLAY"
  run "bwe12M+playout0#$rep" W=1920 H=1248 SECONDS=16 BWE_START=12000000 "TRIALS=$PLAY"
done
run "REFRESH base+lateBWE12M+IDR@9s" W=1920 H=1248 SECONDS=18 WARMUP=1 SERIES=1 REFRESH_AT=9 BWE_LATE=12000000
run "REFRESH playout0+lateBWE12M+IDR@9s" W=1920 H=1248 SECONDS=18 WARMUP=1 SERIES=1 REFRESH_AT=9 BWE_LATE=12000000 "TRIALS=$PLAY"
run "REFRESH playout0+bwe12M start+IDR@9s pace30" W=1920 H=1248 SECONDS=18 WARMUP=1 SERIES=1 REFRESH_AT=9 BWE_START=12000000 "TRIALS=$PLAY;WebRTC-Video-Pacing=factor:2.5,max_delay:30ms"
run "REFRESH playout0+bwe12M start+IDR@9s default-pacing" W=1920 H=1248 SECONDS=18 WARMUP=1 SERIES=1 REFRESH_AT=9 BWE_START=12000000 "TRIALS=$PLAY"
echo "### DONE" >> $OUT
