#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

device="${DEVICE:-}"
team="${DEVELOPMENT_TEAM:-}"
destination="${XCODE_DESTINATION:-}"

if [[ -z "$device" ]]; then
  cat >&2 <<'USAGE'
Set DEVICE to the iPhone identifier or name that devicectl can install to.

Examples:
  DEVICE=00008120-001135213A00C01E DEVELOPMENT_TEAM=ABCDE12345 Tools/install-to-iphone.sh
  DEVICE="Axel's iPhone" XCODE_DESTINATION="platform=iOS,name=Axel's iPhone" Tools/install-to-iphone.sh

Run Tools/device-preflight.sh first to check device visibility and signing.
USAGE
  exit 2
fi

if [[ -z "$destination" ]]; then
  destination="platform=iOS,id=$device"
fi

build_settings=()
if [[ -n "$team" ]]; then
  build_settings+=("DEVELOPMENT_TEAM=$team")
fi

echo "== Building FlowMotion for iPhone =="
echo "Destination: $destination"
if [[ -n "$team" ]]; then
  echo "Development Team: $team"
else
  echo "Development Team: using project/Xcode account default"
fi

xcodebuild \
  -project FlowMotion.xcodeproj \
  -scheme FlowMotion \
  -configuration Debug \
  -destination "$destination" \
  -destination-timeout 30 \
  -derivedDataPath Build/DerivedData \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  "${build_settings[@]}" \
  build

app_path="Build/DerivedData/Build/Products/Debug-iphoneos/FlowMotion.app"
if [[ ! -d "$app_path" ]]; then
  echo "Expected app was not produced at $app_path" >&2
  exit 3
fi

echo
echo "== Installing FlowMotion on $device =="
xcrun devicectl device install app \
  --device "$device" \
  "$app_path" \
  --timeout 60

echo
echo "Install finished. Open FlowMotion on the iPhone and accept Camera, Microphone, Bluetooth, and Photos prompts."
