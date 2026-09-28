#!/bin/sh
# Shared helpers for deploy-cloudflare.sh, teardown-cloudflare.sh and rotate-turn-key.sh.
# Sourced, never executed. POSIX sh.

apply=0
missing_count=0
public_blocked=0

relay_say() { printf '%s\n' "$*"; }
relay_step() { printf '\n== %s\n' "$*"; }
relay_die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

relay_missing() {
  printf '  - %s\n' "$1" >&2
  missing_count=$((missing_count + 1))
}

relay_require_none_missing() {
  if [ "$missing_count" -gt 0 ]; then
    printf 'refusing to continue: %s prerequisite(s) missing (listed above). Nothing was changed.\n' "$missing_count" >&2
    exit 78
  fi
}

relay_init_paths() {
  [ -n "${HOME:-}" ] || relay_die "HOME is not set" 64
  relay_home=${POCKETDESK_HOME:-$HOME/.pocketdesk/relay}
  relay_env=${POCKETDESK_RELAY_ENV:-$relay_home/relay.env}
  app_dir=$relay_home/app
  agents_dir=${POCKETDESK_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}
  log_dir=${POCKETDESK_LOG_DIR:-$HOME/Library/Logs/PocketDesk}
  cloudflared_home=${CLOUDFLARED_HOME:-$HOME/.cloudflared}
  signal_label=com.pocketdesk.relay.signal
  tunnel_label=com.pocketdesk.relay.tunnel
  uid=$(id -u)
  export POCKETDESK_HOME="$relay_home"
}

relay_cfg() { bun "$here/relay-env.ts" get "$1" --env-file "$relay_env"; }
relay_cfg_or() { relay_cfg "$1" 2>/dev/null || printf '%s\n' "$2"; }

relay_print_command() {
  printf '%s' "$1"
  shift
  for argument in "$@"; do printf ' %s' "$argument"; done
  printf '\n'
}

relay_run() {
  class=$1
  shift
  if [ "$apply" != 1 ]; then
    printf '[dry-run][%s] ' "$class"
    relay_print_command "$@"
    return 0
  fi
  if [ "$class" = PUBLIC ] && [ "${POCKETDESK_APPROVE_PUBLIC:-}" != yes ]; then
    printf '[blocked][PUBLIC] not run (set POCKETDESK_APPROVE_PUBLIC=yes to allow): '
    relay_print_command "$@"
    public_blocked=1
    return 0
  fi
  printf '+ [%s] ' "$class"
  relay_print_command "$@"
  "$@"
}

relay_render() {
  template=$1
  output=$2
  shift 2
  sed_script=$(mktemp "${TMPDIR:-/tmp}/pocketdesk-render.XXXXXX")
  for pair in "$@"; do
    key=${pair%%=*}
    value=${pair#*=}
    case $value in
      *'|'*|*'&'*|*'\'*) rm -f "$sed_script"; relay_die "unsafe character in value for $key" 64 ;;
    esac
    case $value in
      *'
'*) rm -f "$sed_script"; relay_die "newline in value for $key" 64 ;;
    esac
    printf 's|@%s@|%s|g\n' "$key" "$value" >>"$sed_script"
  done
  sed -f "$sed_script" "$template" >"$output"
  rm -f "$sed_script"
  if grep -q '@[A-Z_]*@' "$output"; then
    relay_die "unresolved placeholder in $output" 70
  fi
}

relay_bun_path() { command -v bun; }

relay_wait_ready() {
  port=$1
  attempts=0
  while [ "$attempts" -lt 30 ]; do
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/ready" >/dev/null 2>&1; then return 0; fi
    sleep 1
    attempts=$((attempts + 1))
  done
  return 1
}
