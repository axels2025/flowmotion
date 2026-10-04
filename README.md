# FlowMotion

Native SwiftUI iPhone app for recording video and taking photos from gimbal button events sent over Bluetooth Low Energy.

## Current behavior

- Scans for the configured BLE service UUID.
- Scans broadly and connects to a peripheral matching the configured device name or advertising the configured service UUID.
- Starts the BLE connection attempt automatically when the app opens.
- Discovers the configured service after connection.
- Subscribes only to `B11C0007-672A-8DAB-F442-A0DAB5063A98` for button actions.
- Parses button packets containing `0x0100` / `01 00` for the red button and `0x0200` / `02 00` for the white button.
- Red single tap toggles video recording.
- Red double tap captures a photo.
- On-screen zoom selector supports `0.5x`, `1x`, `2x`, and `3x` where the iPhone camera hardware supports those zoom levels.
- Top-left quality selector supports `HD` / `4K` and `24` / `30` / `60` FPS. Unsupported combinations fall back to the closest supported recording format.
- Top-right flash selector supports light `On`, `Auto`, and `Off`; photo capture uses the same setting when the active camera has flash.
- The flash panel includes an exposure bias slider from `-2` to `+2`.
- The flash panel includes `Action`, which enables the strongest video stabilization mode supported by the current camera format and otherwise stays unavailable.
- A small gyro toggle under the flash icon displays a live level overlay with a tilt line and roll angle in degrees.
- Bottom-right camera switch toggles between rear and front camera when not recording.
- Red long press is ignored for now because the verified device did not emit a reliable hold event.
- Zero-only button packets are treated as idle/noise and ignored.
- The main screen has no on-screen record, photo, or connection controls; recording/photo capture are handled by the gimbal buttons.
- Video preview, recordings, and photos follow the iPhone's physical portrait/landscape orientation.
- White button events are ignored by the app; the gimbal can keep using them for its own pan/tilt behavior. The app does not send motor/orientation commands because no verified portrait/landscape command has been found.
- Recording start/stop writes `01` / `00` to `B11C0005-672A-8DAB-F442-A0DAB5063A98` so the gimbal record LED mirrors the app recording state.
- Captured media is imported into the native iPhone Photos library.
- The app defaults to the likely zero-corrected UUID `B11C0001-672A-8DAB-F442-A0DAB5063A98`.
- If a typed UUID contains the letter `O` and replacing it with zeroes produces a valid UUID, the app shows that candidate and lets you apply it explicitly.

## Verified device details

The supplied service UUID is:

```text
B11C0001-672A-8DAB-F442-AODAB5O63A98
```

That value contains the letter `O`, which is not valid in a BLE UUID. The app shows the value exactly as supplied and requires a valid UUID before scanning. Confirm whether the intended UUID uses zeroes, for example in the final group.

The current default assumes those characters are zeroes:

```text
B11C0001-672A-8DAB-F442-A0DAB5063A98
```

Live exploration of `FM ONE - 2280` found:

- Manufacturer: `FlowMotion Technologies AS`
- Model: `FMONE`
- Serial: `784B4A25-2AFE2280`
- Hardware: `2.3`
- Firmware: `3.3.1`
- Software: `3.0.2`
- Button service: `B11C0001-672A-8DAB-F442-A0DAB5063A98`
- Record LED characteristic: `B11C0005-672A-8DAB-F442-A0DAB5063A98`, write `01` for on and `00` for off
- Button characteristic: `B11C0007-672A-8DAB-F442-A0DAB5063A98`
- Red press packet: `01 00`
- White press packet: `02 00`
- Keepalive/status characteristic: `B11C0006-672A-8DAB-F442-A0DAB5063A98`, repeating `00 00 00 00 00 00 00 00`

The observed red long press did not emit a button packet on the discovered button characteristic. The app therefore does not guess long press from silence; it will only fire long press if a future firmware mode emits a release, repeated press, or explicit hold signal.

No verified BLE command for switching phone orientation between portrait and landscape has been found. Do not add writes to the gimbal motor-control characteristics until the command is captured from a known-good app or otherwise verified.

The BLE explorer now calls out whether the gimbal exposes standard HID service `1812`. If that service appears in a different gimbal mode, the next test is pairing it from iOS Bluetooth settings and trying Apple Camera directly.

If landscape does not hold after manually rotating the phone, test with the app disconnected first. If the gimbal also fails to hold landscape without any BLE connection, the problem is mechanical balance, clamp position, calibration, motor torque, or gimbal mode rather than the app.

## Install on an iPhone

1. Open `FlowMotion.xcodeproj` in Xcode.
2. Select the `FlowMotion` target.
3. Set your Apple Developer Team under Signing & Capabilities.
4. Connect the iPhone and select it as the run destination.
5. Build and run.

Before installing, this helper checks whether Xcode can see an available iPhone and whether the Mac has a valid code-signing identity:

```sh
Tools/device-preflight.sh
```

Once preflight passes, the command-line install path is:

```sh
DEVICE=00008120-001135213A00C01E DEVELOPMENT_TEAM=ABCDE12345 Tools/install-to-iphone.sh
```

`DEVICE` can also be a devicectl-recognized device name. If Xcode needs a different destination selector, set `XCODE_DESTINATION`, for example:

```sh
DEVICE="Axel's iPhone" XCODE_DESTINATION="platform=iOS,name=Axel's iPhone" Tools/install-to-iphone.sh
```

## Local checks

```sh
swiftc FlowMotion/ButtonInterpreter.swift ButtonInterpreterSmokeTests/main.swift -o /tmp/flowmotion-button-tests
/tmp/flowmotion-button-tests

xcodebuild -project FlowMotion.xcodeproj -scheme FlowMotion -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath Build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

## License

Released under the [MIT License](LICENSE).
