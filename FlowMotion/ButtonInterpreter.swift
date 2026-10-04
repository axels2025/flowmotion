import Foundation

enum GimbalButton: String, Equatable {
    case red
    case white

    var title: String {
        switch self {
        case .red:
            return "Red"
        case .white:
            return "White"
        }
    }

    var advertisedHexCode: String {
        switch self {
        case .red:
            return "0x0100"
        case .white:
            return "0x0200"
        }
    }
}

enum GimbalButtonGesture: String, Equatable {
    case singleTap
    case doubleTap
    case longPress

    var title: String {
        switch self {
        case .singleTap:
            return "Single"
        case .doubleTap:
            return "Double"
        case .longPress:
            return "Hold"
        }
    }
}

struct GimbalButtonEvent: Identifiable, Equatable {
    let id = UUID()
    let button: GimbalButton
    let gesture: GimbalButtonGesture
    let date: Date
}

enum BLEButtonSignal: Equatable {
    case press(GimbalButton)
    case release
}

enum BLEButtonPacketParser {
    static func parse(_ data: Data) -> BLEButtonSignal? {
        let bytes = Array(data)
        guard !bytes.isEmpty else {
            return nil
        }

        if bytes.allSatisfy({ $0 == 0x00 }) {
            return nil
        }

        guard bytes.count >= 2 else {
            return nil
        }

        for index in 0..<(bytes.count - 1) {
            let first = bytes[index]
            let second = bytes[index + 1]

            if (first == 0x01 && second == 0x00) || (first == 0x00 && second == 0x01) {
                return .press(.red)
            }

            if (first == 0x02 && second == 0x00) || (first == 0x00 && second == 0x02) {
                return .press(.white)
            }
        }

        return nil
    }
}

final class ButtonInterpreter {
    var onEvent: ((GimbalButtonEvent) -> Void)?

    private let doubleTapWindow: TimeInterval
    private let longPressThreshold: TimeInterval
    private let debounceWindow: TimeInterval
    private var pendingButton: GimbalButton?
    private var tapCount = 0
    private var tapTimer: Timer?
    private var activeButton: GimbalButton?
    private var activePressDate: Date?
    private var emittedLongPress = false
    private var releaseAware = false
    private var fallbackPressWasCounted = false
    private var lastFallbackPressDate: Date?

    init(doubleTapWindow: TimeInterval = 1.1, longPressThreshold: TimeInterval = 0.9, debounceWindow: TimeInterval = 0.08) {
        self.doubleTapWindow = doubleTapWindow
        self.longPressThreshold = longPressThreshold
        self.debounceWindow = debounceWindow
    }

    func registerPress(_ button: GimbalButton, at date: Date = Date()) {
        if releaseAware {
            registerReleaseAwarePress(button, at: date)
            return
        }

        if let lastFallbackPressDate,
           date.timeIntervalSince(lastFallbackPressDate) < debounceWindow {
            return
        }

        activeButton = button
        activePressDate = date
        emittedLongPress = false
        fallbackPressWasCounted = true
        lastFallbackPressDate = date
        registerTap(button, at: date)
    }

    func registerRelease(at date: Date = Date()) {
        releaseAware = true

        guard let button = activeButton, let start = activePressDate else {
            return
        }

        let duration = date.timeIntervalSince(start)
        activeButton = nil
        activePressDate = nil
        lastFallbackPressDate = nil

        if emittedLongPress {
            emittedLongPress = false
            fallbackPressWasCounted = false
            return
        }

        if duration >= longPressThreshold, !emittedLongPress {
            cancelTapSequence()
            emittedLongPress = false
            fallbackPressWasCounted = false
            emit(button: button, gesture: .longPress, at: date)
            return
        }

        if !fallbackPressWasCounted {
            registerTap(button, at: date)
        }

        fallbackPressWasCounted = false
        emittedLongPress = false
    }

    private func registerReleaseAwarePress(_ button: GimbalButton, at date: Date) {
        if activeButton == button, let start = activePressDate {
            if !emittedLongPress && date.timeIntervalSince(start) >= longPressThreshold {
                cancelTapSequence()
                emittedLongPress = true
                emit(button: button, gesture: .longPress, at: date)
            }
            return
        }

        activeButton = button
        activePressDate = date
        emittedLongPress = false
        fallbackPressWasCounted = false
    }

    private func registerTap(_ button: GimbalButton, at date: Date) {
        if pendingButton == button {
            tapCount += 1
        } else {
            flushPendingTap(at: date)
            pendingButton = button
            tapCount = 1
        }

        tapTimer?.invalidate()
        tapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
            self?.flushPendingTap()
        }
    }

    func settlePendingGesture(at date: Date = Date()) {
        flushPendingTap(at: date)
    }

    private func flushPendingTap(at date: Date = Date()) {
        guard let button = pendingButton, tapCount > 0 else {
            return
        }

        let gesture: GimbalButtonGesture = tapCount >= 2 ? .doubleTap : .singleTap
        pendingButton = nil
        tapCount = 0
        tapTimer?.invalidate()
        tapTimer = nil
        emit(button: button, gesture: gesture, at: date)
    }

    private func cancelTapSequence() {
        pendingButton = nil
        tapCount = 0
        tapTimer?.invalidate()
        tapTimer = nil
    }

    private func emit(button: GimbalButton, gesture: GimbalButtonGesture, at date: Date) {
        onEvent?(GimbalButtonEvent(button: button, gesture: gesture, date: date))
    }
}

extension Data {
    var flowMotionHexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
