#!/bin/sh
# Rotates the Cloudflare TURN key using two alternating Keychain slots. Dry run unless --apply.
#
#   rotate-turn-key.sh [--apply] [--purge-old]
#
# 1. In the Cloudflare dashboard (Realtime, TURN) create a NEW TURN key. Only you can do that.
# 2. Run this script with --apply. It stores the new key ID and token in the idle Keychain slot
#    (the token is typed at the Keychain prompt, never on a command line), verifies that slot by
#    issuing and revoking one credential, flips POCKETDESK_KEYCHAIN_SLOT, and restarts the service.
# 3. Delete the OLD key in the dashboard. With --purge-old the old Keychain slot is deleted too.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
. "$here/relay-lib.sh"

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

purge_old=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --purge-old) purge_old=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done

relay_init_paths
[ "$(uname -s)" = Darwin ] || relay_die "macOS is required (Keychain and launchd)" 69
if [ "$apply" = 1 ]; then mode=APPLY; else mode=dry-run; fi
relay_step "TURN key rotation, mode: $mode"

for tool in bun security launchctl curl; do
  command -v "$tool" >/dev/null 2>&1 || relay_missing "$tool is not installed"
done
[ -f "$relay_env" ] || relay_missing "$relay_env is missing"
relay_require_none_missing

old_slot=$(relay_cfg_or POCKETDESK_KEYCHAIN_SLOT a)
new_slot=$(bun "$here/relay-env.ts" other-slot --env-file "$relay_env")
port=$(relay_cfg_or PORT 8787)
new_id_service=$(bun "$here/relay-env.ts" keychain-service turn-key-id --slot "$new_slot" --env-file "$relay_env")
new_token_service=$(bun "$here/relay-env.ts" keychain-service turn-api-token --slot "$new_slot" --env-file "$relay_env")
old_id_service=$(bun "$here/relay-env.ts" keychain-service turn-key-id --slot "$old_slot" --env-file "$relay_env")
old_token_service=$(bun "$here/relay-env.ts" keychain-service turn-api-token --slot "$old_slot" --env-file "$relay_env")
relay_say "active slot: $old_slot; the new key goes into slot: $new_slot"

store_new_key() {
  printf 'New TURN key ID (32 characters, shown on screen): '
  read -r new_key_id
  case $new_key_id in
    *[!A-Za-z0-9]*|'') relay_die "the key ID must be 32 letters and digits" 64 ;;
  esac
  [ "${#new_key_id}" -eq 32 ] || relay_die "the key ID must be 32 letters and digits" 64
  login_user=${USER:-$(id -un)}
  security add-generic-password -U -a "$login_user" -s "$new_id_service" -w "$new_key_id"
  printf 'Next, paste the new TURN API token at the Keychain prompt (hidden).\n'
  security add-generic-password -U -a "$login_user" -s "$new_token_service" -w
}

relay_step "Store the new key in slot $new_slot [LOCAL]"
if security find-generic-password -s "$new_id_service" >/dev/null 2>&1 && security find-generic-password -s "$new_token_service" >/dev/null 2>&1; then
  relay_say "slot $new_slot already holds a key ID and token; using them"
else
  relay_run LOCAL store_new_key
fi

relay_step "Verify slot $new_slot against Cloudflare (issues and revokes one credential)"
if [ "$apply" = 1 ]; then
  bun "$here/readiness.ts" --env-file "$relay_env" --slot "$new_slot" || relay_die "the new key failed verification; the active slot was not changed" 70
else
  relay_say "[dry-run] bun $here/readiness.ts --env-file $relay_env --slot $new_slot"
fi

relay_step "Switch to slot $new_slot and restart the service [LOCAL]"
relay_run LOCAL bun "$here/relay-env.ts" set POCKETDESK_KEYCHAIN_SLOT "$new_slot" --env-file "$relay_env"
if launchctl print "gui/$uid/$signal_label" >/dev/null 2>&1; then
  relay_run LOCAL launchctl kickstart -k "gui/$uid/$signal_label"
  if [ "$apply" = 1 ]; then
    relay_wait_ready "$port" || relay_die "the service did not report ready after the restart; see $log_dir/relay-signal.log" 70
    relay_say "service restarted and ready"
  fi
else
  relay_say "$signal_label is not loaded; the next start uses slot $new_slot"
fi

if [ "$purge_old" = 1 ]; then
  relay_step "Delete the old Keychain slot $old_slot [LOCAL]"
  for service in "$old_id_service" "$old_token_service"; do
    if security find-generic-password -s "$service" >/dev/null 2>&1; then
      relay_run LOCAL security delete-generic-password -s "$service"
    fi
  done
fi

relay_step "Steps only you can do"
relay_say "Delete the OLD TURN key in the Cloudflare dashboard (Realtime, TURN). Until then it still issues credentials."
if [ "$apply" != 1 ]; then relay_say "dry run complete: no state was changed."; fi
