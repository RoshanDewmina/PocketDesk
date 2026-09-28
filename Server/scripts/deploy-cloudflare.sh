#!/bin/sh
# Idempotent deployment of the PocketDesk signaling service behind a Cloudflare named tunnel.
#
#   deploy-cloudflare.sh            dry run: read-only checks plus a printed plan (default)
#   deploy-cloudflare.sh --apply    perform LOCAL and ACCOUNT steps
#   POCKETDESK_APPROVE_PUBLIC=yes deploy-cloudflare.sh --apply
#                                   also perform PUBLIC steps (DNS record, tunnel launch agent)
#
# Refuses to run (exit 78) unless the relay environment file, both Keychain secrets and the
# cloudflared login certificate exist. Secret values are never printed.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
server_dir=$(cd "$here/.." && pwd)
. "$here/relay-lib.sh"

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done

relay_init_paths
[ "$(uname -s)" = Darwin ] || relay_die "macOS is required (Keychain and launchd)" 69

if [ "$apply" = 1 ]; then mode=APPLY; else mode=dry-run; fi
relay_step "Preflight (read-only), mode: $mode"

for tool in bun cloudflared launchctl security plutil lsof curl; do
  command -v "$tool" >/dev/null 2>&1 || relay_missing "$tool is not installed"
done
[ -f "$relay_env" ] || relay_missing "$relay_env is missing; run: bun $here/relay-env.ts init --host <your-relay-host>"
relay_require_none_missing

host=$(relay_cfg PD_PUBLIC_HOST 2>/dev/null || true)
tunnel_name=$(relay_cfg_or PD_TUNNEL_NAME pocketdesk-relay)
port=$(relay_cfg_or PORT 8787)
[ -n "$host" ] || relay_missing "PD_PUBLIC_HOST is not set in $relay_env"

secret_source=$(relay_cfg_or POCKETDESK_SECRET_SOURCE env)
if [ "$secret_source" = keychain ]; then
  for item in turn-key-id turn-api-token; do
    service=$(bun "$here/relay-env.ts" keychain-service "$item" --env-file "$relay_env")
    security find-generic-password -s "$service" >/dev/null 2>&1 || relay_missing "Keychain item '$service' is missing; store it with: security add-generic-password -a \"\$USER\" -s $service -w"
  done
else
  for name in CLOUDFLARE_TURN_KEY_ID CLOUDFLARE_TURN_KEY_API_TOKEN; do
    [ -n "$(relay_cfg_or "$name" '')" ] || relay_missing "$name is not set in $relay_env (or switch to POCKETDESK_SECRET_SOURCE=keychain)"
  done
fi
[ -f "$cloudflared_home/cert.pem" ] || relay_missing "$cloudflared_home/cert.pem is missing; run: cloudflared tunnel login"
if lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
  launchctl print "gui/$uid/$signal_label" >/dev/null 2>&1 || relay_missing "TCP port $port is already in use by another process"
fi
relay_require_none_missing

bun "$here/readiness.ts" --env-file "$relay_env" --offline >/dev/null || relay_die "offline readiness checks failed; run: bun $here/readiness.ts --env-file $relay_env --offline" 78
relay_say "offline readiness checks passed for wss://$host/signal"

relay_step "Tunnel $tunnel_name [ACCOUNT]"
tunnel_id=$(cloudflared tunnel list -o json 2>/dev/null | bun "$here/relay-env.ts" tunnel-id "$tunnel_name" 2>/dev/null || true)
if [ -n "$tunnel_id" ]; then
  relay_say "tunnel already exists: $tunnel_id"
else
  relay_run ACCOUNT cloudflared tunnel create "$tunnel_name"
  if [ "$apply" = 1 ]; then
    tunnel_id=$(cloudflared tunnel list -o json | bun "$here/relay-env.ts" tunnel-id "$tunnel_name") || relay_die "tunnel was not created" 70
  else
    tunnel_id='<tunnel-uuid>'
  fi
fi
credentials_file=$cloudflared_home/$tunnel_id.json
tunnel_config=$relay_home/cloudflared.yml

relay_step "cloudflared configuration [LOCAL]"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/pocketdesk-deploy.XXXXXX")
chmod 700 "$scratch"
trap 'rm -rf "$scratch"' EXIT INT TERM
if [ "$apply" = 1 ]; then
  [ -f "$credentials_file" ] || relay_die "tunnel credentials file $credentials_file not found" 70
  chmod 600 "$credentials_file"
  candidate_id=$tunnel_id
  candidate_credentials=$credentials_file
else
  candidate_id=00000000-0000-4000-8000-000000000000
  candidate_credentials=$scratch/credentials.json
  : >"$candidate_credentials"
  chmod 600 "$candidate_credentials"
fi
relay_render "$server_dir/deploy/cloudflared.relay.yml.template" "$scratch/cloudflared.yml" \
  "TUNNEL_ID=$candidate_id" "CREDENTIALS_FILE=$candidate_credentials" "PD_PUBLIC_HOST=$host" "PORT=$port"
cloudflared tunnel --config "$scratch/cloudflared.yml" ingress validate >/dev/null
cloudflared tunnel --config "$scratch/cloudflared.yml" ingress rule "https://$host/signal" | grep -q 'Matched rule #0' || relay_die "ingress does not route /signal" 70
for path in / /health /ready /browser-host /signal/extra; do
  cloudflared tunnel --config "$scratch/cloudflared.yml" ingress rule "https://$host$path" | grep -q 'Matched rule #1' || relay_die "ingress exposes $path" 70
done
relay_say "ingress validated: only https://$host/signal is routed; everything else answers 404"
bun "$here/readiness.ts" --env-file "$relay_env" --offline --cloudflared-config "$scratch/cloudflared.yml" >/dev/null || relay_die "rendered cloudflared configuration failed the readiness checks" 70
relay_run LOCAL mkdir -p "$relay_home" "$log_dir" "$agents_dir"
if [ "$apply" = 1 ]; then
  cp "$scratch/cloudflared.yml" "$tunnel_config"
  chmod 600 "$tunnel_config"
  relay_say "wrote $tunnel_config"
else
  relay_say "[dry-run][LOCAL] would write $tunnel_config"
fi

relay_step "Service files [LOCAL]"
bun_path=$(relay_bun_path)
cloudflared_path=$(command -v cloudflared)
install_app() {
  mkdir -p "$app_dir/src"
  rm -f "$app_dir"/src/*.ts
  cp "$server_dir"/src/*.ts "$app_dir/src/"
  cp "$server_dir/package.json" "$app_dir/package.json"
}
relay_say "service source is copied to $app_dir (outside ~/Documents, which launchd agents cannot read without extra privacy grants)"
relay_run LOCAL install_app
signal_plist=$agents_dir/$signal_label.plist
tunnel_plist=$agents_dir/$tunnel_label.plist
relay_render "$server_dir/deploy/$signal_label.plist.template" "$scratch/signal.plist" \
  "BUN=$bun_path" "ENV_FILE=$relay_env" "APP_DIR=$app_dir" "HOME=$HOME" "LOG_DIR=$log_dir"
relay_render "$server_dir/deploy/$tunnel_label.plist.template" "$scratch/tunnel.plist" \
  "CLOUDFLARED=$cloudflared_path" "CF_CONFIG=$tunnel_config" "TUNNEL_NAME=$tunnel_name" "HOME=$HOME" "LOG_DIR=$log_dir"
plutil -lint "$scratch/signal.plist" "$scratch/tunnel.plist" >/dev/null
if [ "$apply" = 1 ]; then
  cp "$scratch/signal.plist" "$signal_plist"
  cp "$scratch/tunnel.plist" "$tunnel_plist"
  chmod 644 "$signal_plist" "$tunnel_plist"
  relay_say "wrote $signal_plist and $tunnel_plist"
else
  relay_say "[dry-run][LOCAL] would write $signal_plist and $tunnel_plist"
fi

relay_step "Signaling service on 127.0.0.1:$port [LOCAL, loopback only]"
if [ "$apply" = 1 ]; then launchctl bootout "gui/$uid/$signal_label" >/dev/null 2>&1 || true; fi
relay_run LOCAL launchctl bootstrap "gui/$uid" "$signal_plist"
if [ "$apply" = 1 ]; then
  relay_wait_ready "$port" || relay_die "the signaling service did not report ready; see $log_dir/relay-signal.log" 70
  relay_say "service is ready on loopback"
  bun "$here/readiness.ts" --env-file "$relay_env" || relay_die "live readiness failed (Cloudflare TURN issuance); nothing is public yet" 70
fi

relay_step "Publish [PUBLIC]"
route_dns() {
  if output=$(cloudflared tunnel route dns "$tunnel_name" "$host" 2>&1); then
    printf '%s\n' "$output"
    return 0
  fi
  case $output in
    *'already exists'*)
      printf 'DNS record already exists; confirm in the Cloudflare dashboard that %s targets %s.cfargotunnel.com\n' "$host" "$tunnel_id"
      return 0 ;;
  esac
  printf '%s\n' "$output" >&2
  return 1
}
relay_say "DNS change: cloudflared tunnel route dns $tunnel_name $host (creates a proxied CNAME to $tunnel_id.cfargotunnel.com)"
relay_run PUBLIC route_dns
if [ "$apply" = 1 ] && [ "$public_blocked" = 0 ]; then launchctl bootout "gui/$uid/$tunnel_label" >/dev/null 2>&1 || true; fi
relay_run PUBLIC launchctl bootstrap "gui/$uid" "$tunnel_plist"

relay_step "Result"
if [ "$apply" != 1 ]; then
  relay_say "dry run complete: no state was changed. Re-run with --apply to perform the LOCAL and ACCOUNT steps."
  relay_say "PUBLIC steps additionally need: POCKETDESK_APPROVE_PUBLIC=yes"
elif [ "$public_blocked" = 1 ]; then
  relay_say "LOCAL and ACCOUNT steps done. PUBLIC steps were skipped; nothing is reachable from the internet."
else
  sleep "${POCKETDESK_TUNNEL_SETTLE_SECONDS:-5}"
  bun "$here/readiness.ts" --env-file "$relay_env" --public || relay_die "public readiness failed; see $log_dir/relay-tunnel.log" 70
  relay_say "Use this signaling URL in PocketDesk Host: wss://$host/signal"
fi
