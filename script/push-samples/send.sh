#!/bin/sh
# Push one sample payload to a booted iOS Simulator, as if APNs had delivered it.
#
#   send.sh <sample> [device]
#
#   sample   a file in this folder, with or without .apns: agent-needs-you, agent-needs-you-active,
#            agent-needs-you-unknown-agent, agent-snooze-reminder, agent-malformed-id, agent-wrong-category
#   device   a simulator UDID or "booted" (default)
#
# The app must have notification permission (Settings, Alerts & Lock Screen, Agent alerts on). No real
# push is sent and no APNs key is involved: this is simctl's own delivery path.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
sample=${1:?usage: send.sh <sample> [device]}
device=${2:-booted}
bundle=com.roshan.PocketDesk.Remote

case "$sample" in
  *.apns) file="$here/$sample" ;;
  *) file="$here/$sample.apns" ;;
esac
[ -r "$file" ] || { echo "No such sample: $file" >&2; exit 2; }

xcrun simctl push "$device" "$bundle" "$file"
