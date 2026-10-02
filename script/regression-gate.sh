#!/bin/bash
# Run from any integration checkout. Never installs a host or targets a real phone.
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/regression_gate.py" "$@"
