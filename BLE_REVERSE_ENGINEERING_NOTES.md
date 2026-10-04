# FlowMotion ONE BLE reverse-engineering notes

Session date: 2026-06-19
Device: `FM ONE - 2280`

## Device/service layout

Main service:

- `B11C0001-672A-8DAB-F442-A0DAB5063A98`

Private service:

- `B11C0100-672A-8DAB-F442-A0DAB5063A98`

Known characteristics from exploration:

- `B11C0002...`: read/write/notify, normally reads `01`.
- `B11C0003...`: notify; ack-like `00` after `0105` writes.
- `B11C0004...`: read/notify, normally 18 zero bytes.
- `B11C0005...`: read/write/notify, record LED; `01` on, `00` off.
- `B11C0006...`: read/notify, status/joystick, normally 8 zero bytes.
- `B11C0007...`: notify, physical buttons; red `01 00`, white `02 00`.
- `B11C0008...`: read/notify, normally `00`.
- `B11C0009...`: read, app/firmware-facing string `2.0.3`.
- `B11C000A...`: read/write/notify, device name. Do not fuzz casually.
- `B11C0080...`: read/write/notify, reads two floats: `00 00 80 3F 00 00 80 3F` (`1.0, 1.0`). Not fuzzed yet.

Private characteristics:

- `B11C0101...`: read/write/notify, 2 bytes; important for roll/tilt action found below.
- `B11C0102...`: read/write/notify, 8 bytes; accepts float-like vectors, still inconclusive.
- `B11C0103...`: read/write/notify, 1 byte; tested several values, no movement observed.
- `B11C0104...`: read/notify only.
- `B11C0105...`: write/notify, one byte only; writes ack via `0003 = 00`, no movement observed.
- `B11C0110...`: write/notify; accepts 1-, 2-, and 3-byte payloads, no confirmed movement.
- `B11C0111...`: read/write/notify, 1 byte; tested values, no confirmed movement.
- `B11C0112...`: write/notify; accepts 1-, 2-, and 3-byte payloads. One early `05 00` caused a status burst but no observed movement.
- `B11C0113...`: write/notify; accepts 1-, 2-, and 3-byte payloads. No confirmed movement.

## Confirmed roll/tilt action

Characteristic:

`B11C0101-672A-8DAB-F442-A0DAB5063A98`

Observed action:

- In landscape mode, writes starting with `01` cause the phone to tilt forward slightly and the left bottom corner to drop.
- The level app showed a drop from about `0` degrees to about `4` degrees, then it returned partly. One isolated test left about a `2` degree offset until restored.
- The BLE notification pattern for this action is:
  - `01 02`
  - `01 01`
  - `01 00`

Payloads confirmed to trigger the same action pattern:

- `01 00`
- `01 01`
- `01 02`
- `01 FF`

Restore/neutral command:

```text
B11C0101 = 00 00
```

This restored the gimbal/phone back to `0` degrees during testing and leaves `0101` reading/notifying `00 00`.

Practical rule for future tests:

- After any `B11C0101 = 01 xx` test, immediately write `B11C0101 = 00 00`.
- Treat `01 xx` as a coupled action, not a clean roll-only correction.

## B11C0101 negative/opposite search

Tested:

- `02 01` -> accepted, notified as `02 00`, no confirmed movement.
- `03 01` -> accepted, notified as `03 00`, no confirmed movement.
- `02 00`, `03 00`, `04 00` -> accepted as plain state-like writes, no confirmed movement.

Not completed due timeout:

- `04 01`
- `FF 01`

Current interpretation:

- `B11C0101` probably does not encode an obvious opposite roll correction.
- First byte `01` appears to mean "perform this coupled forward/left-bottom-drop action"; other first-byte values look more like state writes.

## B11C0102 vector-style tests

Characteristic:

`B11C0102-672A-8DAB-F442-A0DAB5063A98`

Default/restore value:

```text
B11C0102 = 00 00 00 00 00 00 00 00
```

Tested values:

- `CD CC CC 3D 00 00 00 00` (`+0.1, 0.0` as little-endian floats): accepted; no confirmed movement; later restored to zeros.
- `00 00 00 00 CD CC CC 3D` (`0.0, +0.1`): accepted and restored cleanly; no confirmed movement reported yet.
- `CD CC CC BD 00 00 00 00` (`-0.1, 0.0`): connection timed out before write result; inconclusive.

Recommended next tests:

- Continue `B11C0102` in very short isolated runs with immediate zero restore.
- Avoid negative values until the timeout behavior is understood.
- If `+0.1` does nothing, try larger positive magnitudes first, for example `0.25` (`00 00 80 3E`) or `0.5` (`00 00 00 3F`), one axis at a time.

## Known safe/restore commands

Neutralize `0101` roll/tilt action:

```text
B11C0101 = 00 00
```

Neutralize `0102` vector value:

```text
B11C0102 = 00 00 00 00 00 00 00 00
```

Record LED:

```text
B11C0005 = 01  # LED on
B11C0005 = 00  # LED off
```

## Testing cautions

- Do not fuzz `B11C000A`; it is the device name (`FM ONE - 2280`).
- Do not fuzz standard Device Information or Battery service characteristics.
- `B11C0080` reads as two floats `1.0, 1.0`; it may be configuration/speed-like. Leave it alone unless explicitly testing config.
- The gimbal can time out/disconnect after some writes. If a disconnect occurs before a write result, treat the command as inconclusive and reconnect to send the appropriate restore.

