#!/usr/bin/env python3
"""Usage: ballast.py --gib N [--touch-seconds S]

Holds N GiB of incompressible memory so a 16 GB Mac behaves more like an 8 GB one. The pages are
random bytes, so the memory compressor cannot shrink them, and every page is read again every S
seconds (default 2) so the kernel sees an active working set instead of paging the ballast out
and giving the RAM back. Use --touch-seconds 0 for a cold ballast that the kernel may swap.

Stop it with SIGTERM or Ctrl-C (realistic-load.sh stop does this). Refuses to leave less than
3 GiB of physical memory unallocated."""
import argparse
import os
import signal
import subprocess
import sys
import time

PAGE = 16384
CHUNK = 64 << 20


def physical_bytes():
    return int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]).strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gib", type=float, required=True)
    parser.add_argument("--touch-seconds", type=float, default=2.0)
    args = parser.parse_args()

    target = int(args.gib * (1 << 30))
    if target <= 0 or physical_bytes() - target < 3 * (1 << 30):
        sys.exit(f"ballast: refusing {args.gib} GiB on a {physical_bytes() / (1 << 30):.0f} GiB Mac")

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    blocks, held = [], 0
    while held < target:
        size = min(CHUNK, target - held)
        blocks.append(bytearray(os.urandom(size)))
        held += size
    print(f"ballast: pid {os.getpid()} holding {held / (1 << 30):.2f} GiB, touch every {args.touch_seconds}s", flush=True)

    checksum = 0
    while True:
        if args.touch_seconds <= 0:
            time.sleep(3600)
            continue
        started = time.monotonic()
        for block in blocks:
            checksum ^= sum(block[::PAGE])
        time.sleep(max(0.05, args.touch_seconds - (time.monotonic() - started)))


if __name__ == "__main__":
    main()
