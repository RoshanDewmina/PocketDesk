#!/bin/sh
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "usage: run-bounded-standalone.sh /absolute/service.env /absolute/Caddyfile <quick|/absolute/cloudflared.yml> [seconds]" >&2
  exit 64
fi

service_env=$1
caddy_config=$2
tunnel_mode=$3
duration=${4:-1800}

case "$service_env:$caddy_config" in
  /*:/*) ;;
  *) echo "service and Caddy paths must be absolute" >&2; exit 64 ;;
esac
case "$duration" in *[!0-9]*|'') echo "duration must be an integer" >&2; exit 64 ;; esac
if [ "$duration" -lt 60 ] || [ "$duration" -gt 3600 ]; then
  echo "duration must be between 60 and 3600 seconds" >&2
  exit 64
fi

for command_name in bun caddy cloudflared; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "$command_name is required" >&2; exit 69; }
done

run_dir=$(mktemp -d "${TMPDIR:-/tmp}/pocketdesk-standalone.XXXXXX")
chmod 700 "$run_dir"
service_pid=
proxy_pid=
tunnel_pid=

cleanup() {
  trap - EXIT INT TERM
  for owned_pid in "$tunnel_pid" "$proxy_pid" "$service_pid"; do
    if [ -n "$owned_pid" ] && kill -0 "$owned_pid" 2>/dev/null; then
      kill "$owned_pid" 2>/dev/null || true
    fi
  done
  cleanup_attempt=0
  while [ "$cleanup_attempt" -lt 50 ]; do
    still_running=0
    for owned_pid in "$tunnel_pid" "$proxy_pid" "$service_pid"; do
      if [ -n "$owned_pid" ] && kill -0 "$owned_pid" 2>/dev/null; then still_running=1; fi
    done
    [ "$still_running" -eq 0 ] && break
    sleep 0.1
    cleanup_attempt=$((cleanup_attempt + 1))
  done
  for owned_pid in "$tunnel_pid" "$proxy_pid" "$service_pid"; do
    if [ -n "$owned_pid" ] && kill -0 "$owned_pid" 2>/dev/null; then
      kill -KILL "$owned_pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
  echo "PocketDesk bounded standalone processes stopped; logs: $run_dir"
}
trap cleanup EXIT INT TERM

caddy validate --config "$caddy_config" >/dev/null
bun run readiness --env-file "$service_env"
bun --env-file="$service_env" run src/index.ts >"$run_dir/service.log" 2>&1 &
service_pid=$!
caddy run --config "$caddy_config" >"$run_dir/caddy.log" 2>&1 &
proxy_pid=$!

if [ "$tunnel_mode" = quick ]; then
  cloudflared tunnel --no-autoupdate --url http://127.0.0.1:28788 >"$run_dir/tunnel.log" 2>&1 &
else
  case "$tunnel_mode" in /*) ;; *) echo "tunnel config path must be absolute or quick" >&2; exit 64 ;; esac
  cloudflared tunnel --no-autoupdate --config "$tunnel_mode" run >"$run_dir/tunnel.log" 2>&1 &
fi
tunnel_pid=$!

echo "PocketDesk standalone test started for at most ${duration}s; logs: $run_dir"
elapsed=0
while [ "$elapsed" -lt "$duration" ]; do
  for owned_pid in "$service_pid" "$proxy_pid" "$tunnel_pid"; do
    if ! kill -0 "$owned_pid" 2>/dev/null; then
      echo "a bounded standalone child process exited early; inspect $run_dir" >&2
      exit 1
    fi
  done
  sleep 1
  elapsed=$((elapsed + 1))
done
