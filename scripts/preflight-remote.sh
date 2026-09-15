#!/bin/sh
# Read-only PocketDesk readiness summary. It never reads an environment file,
# launches services, changes permissions, or contacts a provider.
set -u

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_path=/Applications/PocketDesk\ Host.app
device_host=
standalone=0
service_env=
caddy_config=
tunnel_config=
local_failed=0
optional_failed=0

usage() {
  cat <<'EOF'
usage: scripts/preflight-remote.sh [options]

Read-only readiness checks for the private feasibility MVP.

  --app PATH             Installed PocketDesk Host.app (default: /Applications/PocketDesk Host.app)
  --device HOST          Optional ping check for a device or host
  --standalone           Check local prerequisites for the built-in public-test path
  --service-env PATH     Check private regular-file metadata and owner-only permissions; never open it
  --caddy-config PATH    Check private regular-file metadata and owner-only permissions; never open it
  --tunnel-config PATH   Check private regular-file metadata and owner-only permissions; never open it
  -h, --help             Show this help

Exit status is non-zero only when required local checks fail, or when a selected
optional check is blocked. It does not establish runtime Screen Recording,
Accessibility, pairing, WSS, TURN, media, route selection, or phone control.
EOF
}

report() {
  printf '%s: %s\n' "$1" "$2"
}

require_command() {
  name=$1
  if command -v "$name" >/dev/null 2>&1; then
    report PASS "tool/$name available"
  else
    report BLOCKED "tool/$name missing"
    local_failed=1
  fi
}

check_private_file() {
  label=$1
  path=$2
  if [ -z "$path" ]; then
    report UNKNOWN "$label not supplied; not inspected"
  elif [ ! -e "$path" ]; then
    report BLOCKED "$label path is absent"
    optional_failed=1
  elif [ -L "$path" ] || [ ! -f "$path" ]; then
    report BLOCKED "$label must be a regular non-symbolic file"
    optional_failed=1
  else
    mode=$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null || true)
    case "$mode" in
      [0-7][0-7][0-7])
        group=${mode#?}; group=${group%?}
        other=${mode#??}
        case "$group$other" in
          *[1-7]*) report BLOCKED "$label permissions $mode permit group or other access"; optional_failed=1 ;;
          *) report PASS "$label is a regular owner-only file (mode $mode); contents intentionally not read" ;;
        esac ;;
      *) report UNKNOWN "$label regular file found, but permissions could not be determined; contents intentionally not read" ;;
    esac
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app|--device|--service-env|--caddy-config|--tunnel-config)
      [ "$#" -ge 2 ] || { printf '%s requires a value\n' "$1" >&2; usage >&2; exit 64; }
      case "$1" in
        --app) app_path=$2 ;;
        --device) device_host=$2 ;;
        --service-env) service_env=$2 ;;
        --caddy-config) caddy_config=$2 ;;
        --tunnel-config) tunnel_config=$2 ;;
      esac
      shift 2 ;;
    --standalone) standalone=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
done

printf 'PocketDesk MVP preflight (read-only)\n'
report UNKNOWN "runtime privacy permissions require a live host check; signature/build checks cannot prove them"

require_command xcodebuild
require_command xcrun
require_command xcodegen
require_command bun

if [ ! -d "$app_path" ]; then
  report BLOCKED "installed host app absent"
  local_failed=1
elif ! command -v codesign >/dev/null 2>&1; then
  report BLOCKED "tool/codesign missing; installed-app signature cannot be checked"
  local_failed=1
elif codesign --verify --deep --strict --verbose=2 "$app_path" >/dev/null 2>&1; then
  report PASS "installed host app has a strict valid signature"
else
  report BLOCKED "installed host app signature verification failed"
  local_failed=1
fi

for template in \
  Server/.env.standalone.example \
  Server/Caddyfile.standalone.example \
  Server/cloudflared.standalone.yml.example \
  Server/scripts/readiness.ts \
  Server/scripts/run-bounded-standalone.sh; do
  if [ -f "$root_dir/$template" ]; then
    report PASS "standalone template/$template present"
  else
    report BLOCKED "standalone template/$template absent"
    local_failed=1
  fi
done

if [ -n "$device_host" ]; then
  if command -v ping >/dev/null 2>&1 && ping -c 1 -W 1000 "$device_host" >/dev/null 2>&1; then
    report PASS "device/$device_host responds to ping"
  else
    report UNKNOWN "device/$device_host did not answer ping; ICMP alone does not prove app reachability"
  fi
else
  report UNKNOWN "device reachability not requested"
fi

if [ "$standalone" -eq 1 ]; then
  for name in bun caddy cloudflared; do
    if command -v "$name" >/dev/null 2>&1; then
      report PASS "standalone tool/$name available"
    else
      report BLOCKED "standalone tool/$name missing"
      optional_failed=1
    fi
  done
  check_private_file "private service env-file" "$service_env"
  check_private_file "private Caddy config" "$caddy_config"
  check_private_file "private tunnel config" "$tunnel_config"
  report UNKNOWN "provider authorization, WSS, TURN issuance, and relay allocation are not tested by this command"
else
  report UNKNOWN "standalone deployment check not requested; use --standalone when preparing the built-in public-test path"
fi

if [ "$local_failed" -ne 0 ] || [ "$optional_failed" -ne 0 ]; then
  report BLOCKED "preflight has unresolved selected checks"
  exit 1
fi
report PASS "local preflight complete; live device acceptance remains required"
