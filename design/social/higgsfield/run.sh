#!/bin/bash
# Loads the Higgsfield API key from the macOS Keychain for this process only; the value is never written to disk or printed.
set -euo pipefail
HF_CREDENTIALS="$(security find-generic-password -s higgsfield-api -a farside -w)" || { echo "No Keychain item 'higgsfield-api' (account 'farside'). Add it with: security add-generic-password -U -s higgsfield-api -a farside -w" >&2; exit 1; }
export HF_CREDENTIALS
exec bun "$@"
