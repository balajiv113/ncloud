#!/usr/bin/env bash
set -euo pipefail

trap 'touch "$RUNNER_TEMP/ncloud-simulator-failed"' ERR
start=$SECONDS
device=$(xcrun simctl list devices available --json | jq -er \
  '.devices["com.apple.CoreSimulator.SimRuntime.iOS-18-5"][]
   | select(.name == "iPhone 16") | .udid' | head -n 1)
test -n "$device"
printf '%s\n' "$device" > "$RUNNER_TEMP/ncloud-simulator-device"
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device"
echo "Simulator launch and boot: $((SECONDS - start))s" >> "$GITHUB_STEP_SUMMARY"
touch "$RUNNER_TEMP/ncloud-simulator-ready"
