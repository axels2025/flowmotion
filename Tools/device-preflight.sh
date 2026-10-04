#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "== FlowMotion iPhone install preflight =="
echo

device_status=0
signing_status=0
destinations_status=0

echo "-- Devices visible to Xcode --"
if ! xcrun devicectl list devices --timeout 15; then
  echo
  echo "devicectl could not query devices. Open Xcode once, connect the iPhone, and approve any trust prompts."
  device_status=1
fi

echo
echo "-- Code-signing identities --"
identity_output="$(security find-identity -v -p codesigning || true)"
echo "$identity_output"

if echo "$identity_output" | grep -q "0 valid identities found"; then
  echo
  echo "No valid Apple code-signing identities were found in this keychain."
  echo "Open Xcode > Settings > Accounts, sign in with an Apple ID, then set a Team on the FlowMotion target."
  signing_status=2
fi

echo
echo "-- Build destination summary --"
if ! xcodebuild -showdestinations \
  -project FlowMotion.xcodeproj \
  -scheme FlowMotion \
  -derivedDataPath Build/DerivedData; then
  destinations_status=3
fi

echo
if (( device_status == 0 && signing_status == 0 && destinations_status == 0 )); then
  echo "Preflight passed. Build and run from Xcode, or use devicectl to install the signed app."
else
  echo "Preflight found missing install prerequisites."
fi

exit $(( device_status + signing_status + destinations_status ))
