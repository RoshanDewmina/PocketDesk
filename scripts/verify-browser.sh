#!/bin/zsh
# Builds and tests an isolated synthetic sender. Requires local GUI launch access.
set -euo pipefail
cd "${0:A:h:h}"
mode="${1:-interactive}"
[[ "$mode" == interactive || "$mode" == view ]] || { print -u2 'Use interactive or view'; exit 2; }
receipt="${POCKETDESK_BROWSER_RECEIPTS:-$PWD/outputs/browser-check-$(date -u +%Y%m%dT%H%M%SZ)-$mode}"
receipt="${receipt:A}"
# Require a new directory: never chmod or clean files in a caller's existing path.
[[ ! -e "$receipt" && ! -L "$receipt" ]] || { print -u2 'Receipt directory already exists; choose a new path.'; exit 2; }
mkdir -m 700 "$receipt"
export POCKETDESK_BROWSER_RECEIPTS="$receipt" POCKETDESK_FIXTURE_MODE="$mode"
export POCKETDESK_BROWSER_PORT="${POCKETDESK_BROWSER_PORT:-8791}"
export POCKETDESK_BROWSER_URL="http://127.0.0.1:$POCKETDESK_BROWSER_PORT"
service_pid=''
cleanup() {
  if [[ -f "$receipt/fixture.pid" ]]; then
    fixture_pid="$(cat "$receipt/fixture.pid")"
    if [[ "$fixture_pid" == <-> ]] && ps -p "$fixture_pid" -o command= | /usr/bin/grep -q '/PocketDeskBrowserFixture.app/Contents/MacOS/PocketDeskBrowserFixture'; then
      kill -TERM "$fixture_pid" 2>/dev/null || true
    fi
  fi
  [[ -z "$service_pid" ]] || kill -TERM "$service_pid" 2>/dev/null || true
  # Only the newly-created synthetic offer is removed; reports contain no keys.
  [[ ! -f "$receipt/offer.private" ]] || /bin/rm "$receipt/offer.private"
}
trap cleanup EXIT INT TERM
xcodegen generate > "$receipt/project-generation.log" 2>&1
bun test BrowserClient/tests BrowserFixtures > "$receipt/browser-unit-tests.log" 2>&1
xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskBrowserFixture -configuration Debug -derivedDataPath outputs/RemoteBuild build > "$receipt/fixture-build.log" 2>&1
bun scripts/browser-dev.ts > "$receipt/service.log" 2>&1 &
service_pid=$!
for attempt in {1..100}; do
  if /usr/bin/grep -q 'PocketDesk private browser service:' "$receipt/service.log"; then break; fi
  kill -0 "$service_pid" || { cat "$receipt/service.log"; exit 1; }
  sleep 0.1
done
/usr/bin/grep -q 'PocketDesk private browser service:' "$receipt/service.log"
node scripts/browser-lifecycle.cjs > "$receipt/browser-lifecycle.log" 2>&1 || { cat "$receipt/browser-lifecycle.log"; exit 1; }
/usr/bin/open -n -g "$PWD/outputs/RemoteBuild/Build/Products/Debug/PocketDeskBrowserFixture.app" \
  --env "POCKETDESK_BROWSER_URL=ws://127.0.0.1:$POCKETDESK_BROWSER_PORT/browser-host" \
  --env "POCKETDESK_FIXTURE_MODE=$mode" \
  --env "POCKETDESK_FIXTURE_OFFER=$receipt/offer.private" \
  --env "POCKETDESK_FIXTURE_PID=$receipt/fixture.pid" \
  --env "POCKETDESK_FIXTURE_RECEIPT=$receipt/host-receipt.json" \
  --stdout "$receipt/fixture.log" --stderr "$receipt/fixture-errors.log"
for attempt in {1..100}; do
  [[ ! -s "$receipt/offer.private" ]] || break
  sleep 0.1
done
[[ -s "$receipt/offer.private" ]]
node scripts/browser-e2e.cjs > "$receipt/browser-e2e.log" 2>&1 || { cat "$receipt/browser-e2e.log"; exit 1; }
cat "$receipt/browser-e2e.log"
print "Synthetic browser checks passed. Receipts: $receipt"
