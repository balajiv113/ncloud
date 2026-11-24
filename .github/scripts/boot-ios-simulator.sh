#!/usr/bin/env bash
set -euo pipefail

trap 'touch "$RUNNER_TEMP/ncloud-simulator-failed"' ERR
start=$SECONDS
# The simulator that goes with the Xcode this job pins (see DEVELOPER_DIR).
runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-2"
device=$(xcrun simctl list devices available --json | jq -er --arg runtime "$runtime" \
  '.devices[$runtime][] | select(.name == "iPhone 17") | .udid' | head -n 1)
test -n "$device"
printf '%s\n' "$device" > "$RUNNER_TEMP/ncloud-simulator-device"
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device"
echo "Simulator launch and boot: $((SECONDS - start))s" >> "$GITHUB_STEP_SUMMARY"
touch "$RUNNER_TEMP/ncloud-simulator-ready"
