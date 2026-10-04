import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func requireSignal(_ actual: BLEButtonSignal?, _ expected: BLEButtonSignal, _ message: String) {
    require(actual == expected, "\(message): expected \(expected), got \(String(describing: actual))")
}

func requireEvent(
    _ events: [GimbalButtonEvent],
    button: GimbalButton,
    gesture: GimbalButtonGesture,
    _ message: String
) {
    require(events.count == 1, "\(message): expected one event, got \(events.count)")
    require(events[0].button == button, "\(message): wrong button")
    require(events[0].gesture == gesture, "\(message): wrong gesture")
}

let base = Date(timeIntervalSince1970: 1_000)

requireSignal(BLEButtonPacketParser.parse(Data([0x01, 0x00])), .press(.red), "red packet")
requireSignal(BLEButtonPacketParser.parse(Data([0x00, 0x01])), .press(.red), "red packet reversed")
requireSignal(BLEButtonPacketParser.parse(Data([0x02, 0x00])), .press(.white), "white packet")
requireSignal(BLEButtonPacketParser.parse(Data([0x99, 0x02, 0x00])), .press(.white), "embedded white packet")
require(BLEButtonPacketParser.parse(Data([0x00, 0x00])) == nil, "zero packet should be ignored")
require(BLEButtonPacketParser.parse(Data([0x03, 0x00])) == nil, "unknown packet should not parse")

do {
    var events: [GimbalButtonEvent] = []
    let interpreter = ButtonInterpreter(doubleTapWindow: 0.3, longPressThreshold: 0.9, debounceWindow: 0.08)
    interpreter.onEvent = { events.append($0) }

    interpreter.registerPress(.red, at: base)
    interpreter.settlePendingGesture(at: base.addingTimeInterval(0.31))
    requireEvent(events, button: .red, gesture: .singleTap, "fallback single press")
}

do {
    var events: [GimbalButtonEvent] = []
    let interpreter = ButtonInterpreter(doubleTapWindow: 0.3, longPressThreshold: 0.9, debounceWindow: 0.08)
    interpreter.onEvent = { events.append($0) }

    interpreter.registerPress(.red, at: base)
    interpreter.registerPress(.red, at: base.addingTimeInterval(0.2))
    interpreter.settlePendingGesture(at: base.addingTimeInterval(0.51))
    requireEvent(events, button: .red, gesture: .doubleTap, "fallback double press")
}

do {
    var events: [GimbalButtonEvent] = []
    let interpreter = ButtonInterpreter()
    interpreter.onEvent = { events.append($0) }

    interpreter.registerPress(.red, at: base)
    interpreter.registerPress(.red, at: base.addingTimeInterval(1.0))
    interpreter.settlePendingGesture(at: base.addingTimeInterval(2.2))
    requireEvent(events, button: .red, gesture: .doubleTap, "default window accepts captured double press cadence")
}

do {
    var events: [GimbalButtonEvent] = []
    let interpreter = ButtonInterpreter(doubleTapWindow: 0.3, longPressThreshold: 0.9, debounceWindow: 0.08)
    interpreter.onEvent = { events.append($0) }

    interpreter.registerPress(.white, at: base)
    interpreter.registerPress(.white, at: base.addingTimeInterval(0.02))
    interpreter.settlePendingGesture(at: base.addingTimeInterval(0.31))
    requireEvent(events, button: .white, gesture: .singleTap, "fallback debounce")
}

do {
    var events: [GimbalButtonEvent] = []
    let interpreter = ButtonInterpreter(doubleTapWindow: 0.3, longPressThreshold: 0.9, debounceWindow: 0.08)
    interpreter.onEvent = { events.append($0) }

    interpreter.registerPress(.red, at: base)
    interpreter.registerRelease(at: base.addingTimeInterval(0.05))
    interpreter.registerPress(.red, at: base.addingTimeInterval(0.2))
    interpreter.registerRelease(at: base.addingTimeInterval(0.25))
    interpreter.settlePendingGesture(at: base.addingTimeInterval(0.56))
    requireEvent(events, button: .red, gesture: .doubleTap, "release-aware double press")
}

do {
    var events: [GimbalButtonEvent] = []
    let interpreter = ButtonInterpreter(doubleTapWindow: 0.3, longPressThreshold: 0.9, debounceWindow: 0.08)
    interpreter.onEvent = { events.append($0) }

    interpreter.registerPress(.red, at: base)
    interpreter.registerRelease(at: base.addingTimeInterval(1.0))
    requireEvent(events, button: .red, gesture: .longPress, "release long press")
}

do {
    var events: [GimbalButtonEvent] = []
    let interpreter = ButtonInterpreter(doubleTapWindow: 0.3, longPressThreshold: 0.9, debounceWindow: 0.08)
    interpreter.onEvent = { events.append($0) }

    interpreter.registerPress(.white, at: base)
    interpreter.registerRelease(at: base.addingTimeInterval(0.05))
    interpreter.settlePendingGesture(at: base.addingTimeInterval(0.36))
    events.removeAll()

    let holdStart = base.addingTimeInterval(1.0)
    interpreter.registerPress(.red, at: holdStart)
    interpreter.registerPress(.red, at: holdStart.addingTimeInterval(1.0))
    interpreter.registerRelease(at: holdStart.addingTimeInterval(1.1))
    requireEvent(events, button: .red, gesture: .longPress, "repeat-notified long press should not also emit tap")
}

print("ButtonInterpreterSmokeTests passed")
