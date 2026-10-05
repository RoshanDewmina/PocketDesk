#!/bin/sh
# Read-only check of a compiled Release host executable; not a distribution approval.
set -eu
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  printf 'Usage: %s /path/to/Release/host/executable\n' "$0" >&2
  exit 2
fi
if ! /usr/bin/file "$1" | rg -q 'Mach-O'; then
  printf 'Expected a compiled Mach-O executable.\n' >&2
  exit 2
fi
if /usr/bin/strings "$1" | rg -q 'CGVirtualDisplay(Descriptor|Settings|Mode)?'; then
  printf 'Private virtual-display class name found in Release executable.\n' >&2
  exit 1
fi
printf 'Private virtual-display class names excluded from this executable.\n'
