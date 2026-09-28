#!/bin/sh
# Stops and removes the PocketDesk Cloudflare relay. Dry run unless --apply.
#
#   teardown-cloudflare.sh [--apply] [--delete-tunnel] [--purge-secrets] [--purge-files]
#
#   --delete-tunnel   delete the Cloudflare tunnel (ACCOUNT). The DNS record and the TURN key
#                     can only be removed in the Cloudflare dashboard; the script says so.
#   --purge-secrets   delete both TURN Keychain slots
#   --purge-files     delete the copied service source and rendered cloudflared config
#                     (relay.env and the approved-rooms file are kept)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
. "$here/relay-lib.sh"

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

delete_tunnel=0
purge_secrets=0
purge_files=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --delete-tunnel) delete_tunnel=1 ;;
    --purge-secrets) purge_secrets=1 ;;
    --purge-files) purge_files=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done

relay_init_paths
[ "$(uname -s)" = Darwin ] || relay_die "macOS is required (Keychain and launchd)" 69
if [ "$apply" = 1 ]; then mode=APPLY; else mode=dry-run; fi
relay_step "Teardown, mode: $mode"

port=8787
tunnel_name=pocketdesk-relay
if [ -f "$relay_env" ] && command -v bun >/dev/null 2>&1; then
  port=$(relay_cfg_or PORT 8787)
  tunnel_name=$(relay_cfg_or PD_TUNNEL_NAME pocketdesk-relay)
fi

stop_agent() {
  label=$1
  plist=$agents_dir/$label.plist
  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    relay_run LOCAL launchctl bootout "gui/$uid/$label"
  else
    relay_say "$label is not loaded"
  fi
  if [ -f "$plist" ]; then relay_run LOCAL rm -f "$plist"; fi
}

relay_step "Stop public exposure first, then the service [LOCAL]"
stop_agent "$tunnel_label"
stop_agent "$signal_label"

if [ "$delete_tunnel" = 1 ]; then
  relay_step "Delete tunnel $tunnel_name [ACCOUNT]"
  if command -v cloudflared >/dev/null 2>&1 && [ -f "$cloudflared_home/cert.pem" ]; then
    relay_run ACCOUNT cloudflared tunnel cleanup "$tunnel_name"
    relay_run ACCOUNT cloudflared tunnel delete "$tunnel_name"
  else
    relay_say "cloudflared or $cloudflared_home/cert.pem is missing; delete the tunnel in the Cloudflare dashboard instead"
  fi
fi

if [ "$purge_secrets" = 1 ]; then
  relay_step "Delete TURN Keychain items [LOCAL]"
  for slot in a b; do
    for item in turn-key-id turn-api-token; do
      if [ -f "$relay_env" ] && command -v bun >/dev/null 2>&1; then
        service=$(bun "$here/relay-env.ts" keychain-service "$item" --slot "$slot" --env-file "$relay_env")
      elif [ "$slot" = a ]; then
        service=pocketdesk.cloudflare.$item
      else
        service=pocketdesk.cloudflare.$item.$slot
      fi
      if security find-generic-password -s "$service" >/dev/null 2>&1; then
        relay_run LOCAL security delete-generic-password -s "$service"
      fi
    done
  done
fi

if [ "$purge_files" = 1 ]; then
  relay_step "Delete generated files [LOCAL]"
  relay_run LOCAL rm -rf "$app_dir" "$relay_home/cloudflared.yml"
fi

relay_step "Verification"
if [ "$apply" = 1 ]; then
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    relay_say "warning: something is still listening on TCP port $port"
  else
    relay_say "nothing is listening on TCP port $port"
  fi
  if pgrep -f "$relay_home/cloudflared.yml" >/dev/null 2>&1; then
    relay_say "warning: a cloudflared process using $relay_home/cloudflared.yml is still running"
  else
    relay_say "no relay cloudflared process is running"
  fi
else
  relay_say "dry run complete: no state was changed. Re-run with --apply to perform the steps above."
fi

relay_step "Steps only you can do (this script cannot)"
relay_say "1. Cloudflare dashboard, DNS: delete the CNAME for your relay hostname (cloudflared has no 'unroute')."
relay_say "2. Cloudflare dashboard, Realtime, TURN: delete the TURN key. This invalidates every credential it issued."
relay_say "3. Cloudflare dashboard, Billing: confirm Realtime usage is zero for the period."
