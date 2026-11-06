#!/usr/bin/env bash
set -euo pipefail

adb install -r debug/app-debug.apk
adb install -r androidTest/debug/app-debug-androidTest.apk
trap 'adb logcat -d > android-device-logcat.log' EXIT
start=$SECONDS
adb shell am instrument -w \
  app.ncloud.ncloud.test/androidx.test.runner.AndroidJUnitRunner \
  | tee native-android-result.txt
grep -q '^OK (3 tests)' native-android-result.txt
echo "Android native session: $((SECONDS - start))s" >> "$GITHUB_STEP_SUMMARY"

adb shell am force-stop app.ncloud.ncloud
adb forward tcp:8585 tcp:8585
adb shell am start -n app.ncloud.ncloud/.MainActivity \
  --ez enable-dart-profiling true --ez disable-service-auth-codes true \
  --ei vm-service-port 8585
for attempt in $(seq 1 45); do
  if curl -fsS http://127.0.0.1:8585/getVM >/dev/null; then break; fi
  sleep 1
done
curl -fsS http://127.0.0.1:8585/getVM >/dev/null
start=$SECONDS
VM_SERVICE_URL=http://127.0.0.1:8585 dart run test_driver/mobile_test.dart \
  | tee android-device-contract.log
echo "Shared mobile checks: $((SECONDS - start))s" >> "$GITHUB_STEP_SUMMARY"
