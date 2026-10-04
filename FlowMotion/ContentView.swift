import CoreMotion
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var ble = BLEGimbalController()
    @StateObject private var level = MotionLevelController()
    @State private var showQualityMenu = false
    @State private var showCameraSettingsMenu = false

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            ZStack {
                CameraPreview(session: camera.session, videoOrientation: camera.videoOrientation)
                    .ignoresSafeArea()

                if camera.isAuthorized, level.isEnabled {
                    gyroLevelOverlay
                        .allowsHitTesting(false)
                }

                if camera.isAuthorized {
                    cleanOverlay(isLandscape: isLandscape)
                } else {
                    Color.black.opacity(0.72)
                        .ignoresSafeArea()
                    permissionPanel
                }

                if showQualityMenu, camera.isAuthorized {
                    qualityMenuOverlay
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if showCameraSettingsMenu, camera.isAuthorized {
                    cameraSettingsMenuOverlay
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            camera.prepare()
            ble.scanAndConnect()
        }
        .onDisappear {
            camera.stopSession()
            level.stop()
            ble.setRecordLED(isOn: false)
        }
        .onChange(of: camera.isRecording) { _, isRecording in
            ble.setRecordLED(isOn: isRecording)
        }
        .onChange(of: ble.recordLEDState) { _, state in
            if state == "Ready" {
                ble.setRecordLED(isOn: camera.isRecording)
            }
        }
        .onChange(of: ble.lastGesture?.id) { _, _ in
            guard let event = ble.lastGesture else {
                return
            }
            handle(event)
        }
    }

    private func cleanOverlay(isLandscape: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                qualityButton

                if camera.isRecording {
                    recordingPill
                        .padding(.leading, 8)
                }

                Spacer()

                VStack(spacing: 8) {
                    flashButton
                    gyroButton
                }
            }

            Spacer(minLength: 12)

            HStack(alignment: .bottom) {
                zoomSelector
                Spacer()
                cameraSwitchButton
            }
        }
        .padding(.horizontal, isLandscape ? 12 : 18)
        .padding(.vertical, isLandscape ? 8 : 14)
    }

    private var recordingPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)

            Text("REC")
                .font(.caption.weight(.bold))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var cameraSwitchButton: some View {
        Button {
            showQualityMenu = false
            showCameraSettingsMenu = false
            camera.toggleCameraPosition()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 34, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
        }
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.45 : 1)
        .accessibilityLabel("Switch camera")
    }

    private var flashButton: some View {
        Button {
            showQualityMenu = false
            showCameraSettingsMenu.toggle()
        } label: {
            Image(systemName: camera.flashSetting.iconName)
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Flash and exposure")
    }

    private var gyroButton: some View {
        Button {
            showQualityMenu = false
            showCameraSettingsMenu = false
            level.toggle()
        } label: {
            Image(systemName: "gyroscope")
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(level.isEnabled ? .black : .white)
                .frame(width: 38, height: 38)
                .background(level.isEnabled ? Color.white : Color.clear, in: Circle())
                .background(.ultraThinMaterial, in: Circle())
        }
        .disabled(!level.isAvailable)
        .opacity(level.isAvailable ? 1 : 0.35)
        .accessibilityLabel(level.isEnabled ? "Hide gyro level" : "Show gyro level")
    }

    private var gyroLevelOverlay: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let lineLength = min(max(size.width * 0.72, 180), size.width - 72)
            let yPosition = size.height * 0.48
            let roll = Double(level.rollDegrees)
            let readoutX = (size.width + lineLength) / 2
            let readoutY = yPosition - 18

            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: lineLength, height: 1)
                    .position(x: size.width / 2, y: yPosition)

                ZStack {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: lineLength, height: 2)

                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: 12)
                }
                .rotationEffect(.degrees(-roll))
                .position(x: size.width / 2, y: yPosition)

                Text(String(format: "%+.1f deg", roll))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .position(x: readoutX, y: readoutY)
            }
        }
    }

    private var zoomSelector: some View {
        HStack(spacing: 6) {
            ForEach(CameraZoomPreset.allCases) { preset in
                Button {
                    camera.setZoom(preset)
                } label: {
                    Text(preset.title)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .frame(minWidth: 34)
                        .padding(.vertical, 7)
                        .foregroundStyle(camera.selectedZoomPreset == preset ? .black : .white)
                        .background(
                            camera.selectedZoomPreset == preset ? Color.white : Color.clear,
                            in: Capsule()
                        )
                }
                .accessibilityLabel("Set zoom \(preset.title)")
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var qualityButton: some View {
        Button {
            showCameraSettingsMenu = false
            showQualityMenu.toggle()
        } label: {
            HStack(spacing: 10) {
                qualityStack(primary: camera.selectedVideoResolution.title, secondary: "RES")

                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: 28)

                qualityStack(primary: camera.selectedFrameRate.title, secondary: "FPS")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .accessibilityLabel("Video quality")
    }

    private func qualityStack(primary: String, secondary: String) -> some View {
        VStack(spacing: 0) {
            Text(primary)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(secondary)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(minWidth: 28)
    }

    private var qualityMenuOverlay: some View {
        VStack {
            HStack {
                qualityPanel
                Spacer()
            }
            Spacer()
        }
        .padding(.leading, 18)
        .padding(.top, 58)
    }

    private var qualityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RES")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showQualityMenu = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                }
                .accessibilityLabel("Close quality menu")
            }

            HStack(spacing: 8) {
                ForEach(CameraVideoResolution.allCases) { resolution in
                    qualityChoice(
                        title: resolution.title,
                        isSelected: camera.selectedVideoResolution == resolution,
                        isEnabled: !camera.isRecording
                    ) {
                        camera.setVideoResolution(resolution)
                    }
                }
            }

            Text("FPS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(CameraFrameRate.allCases) { frameRate in
                    qualityChoice(
                        title: frameRate.title,
                        isSelected: camera.selectedFrameRate == frameRate,
                        isEnabled: !camera.isRecording
                    ) {
                        camera.setFrameRate(frameRate)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 170)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var cameraSettingsMenuOverlay: some View {
        VStack {
            HStack {
                Spacer()
                cameraSettingsPanel
            }
            Spacer()
        }
        .padding(.trailing, 18)
        .padding(.top, 58)
    }

    private var cameraSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FLASH")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showCameraSettingsMenu = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                }
                .accessibilityLabel("Close flash menu")
            }

            HStack(spacing: 8) {
                ForEach(CameraFlashSetting.allCases) { setting in
                    flashChoice(
                        title: setting.title,
                        isSelected: camera.flashSetting == setting
                    ) {
                        camera.setFlashSetting(setting)
                    }
                }
            }

            HStack {
                Text("EXPOSURE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.1f", Double(camera.exposureBias)))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
            }

            Slider(
                value: Binding(
                    get: { Double(camera.exposureBias) },
                    set: { camera.setExposureBias(Float($0)) }
                ),
                in: -2...2,
                step: 0.1
            )
            .tint(.white)

            HStack {
                Text("-2")
                Spacer()
                Text("+2")
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)

            Toggle(
                isOn: Binding(
                    get: { camera.actionModeEnabled },
                    set: { camera.setActionModeEnabled($0) }
                )
            ) {
                Label("ACTION", systemImage: "figure.run")
                    .font(.caption.weight(.bold))
            }
            .disabled(camera.isRecording || !camera.actionModeAvailable)
            .opacity(camera.isRecording || !camera.actionModeAvailable ? 0.45 : 1)
        }
        .padding(12)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func flashChoice(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? .black : .white)
                .background(isSelected ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
    }

    private func qualityChoice(
        title: String,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? .black : .white)
                .background(isSelected ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var permissionPanel: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 44))

            Text(camera.statusMessage)
                .font(.headline)
                .multilineTextAlignment(.center)

            Button("Retry") {
                camera.prepare()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(24)
    }

    private func handle(_ event: GimbalButtonEvent) {
        switch (event.button, event.gesture) {
        case (.red, .singleTap):
            camera.toggleRecording()
        case (.red, .doubleTap):
            camera.capturePhoto()
        case (.red, .longPress):
            break
        case (.white, .singleTap):
            break
        case (.white, .doubleTap):
            break
        case (.white, .longPress):
            break
        }
    }
}

final class MotionLevelController: NSObject, ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isAvailable: Bool
    @Published private(set) var rollDegrees: Float = 0

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var deviceOrientation: UIDeviceOrientation = .portrait

    override init() {
        isAvailable = motionManager.isDeviceMotionAvailable
        super.init()
        motionQueue.name = "com.flowmotion.motion.level"
        motionQueue.qualityOfService = .userInteractive
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        updateDeviceOrientation()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    func toggle() {
        if isEnabled {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            DispatchQueue.main.async {
                self.isAvailable = false
                self.isEnabled = false
            }
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else {
                return
            }

            let roll = Self.rollDegrees(from: gravity, orientation: self.deviceOrientation)
            DispatchQueue.main.async {
                self.rollDegrees = roll
            }
        }

        isAvailable = true
        isEnabled = true
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        DispatchQueue.main.async { [weak self] in
            self?.isEnabled = false
            self?.rollDegrees = 0
        }
    }

    @objc private func deviceOrientationDidChange() {
        updateDeviceOrientation()
    }

    private func updateDeviceOrientation() {
        let orientation = UIDevice.current.orientation
        if orientation.isPortrait || orientation.isLandscape {
            deviceOrientation = orientation
        }
    }

    private static func rollDegrees(from gravity: CMAcceleration, orientation: UIDeviceOrientation) -> Float {
        let x: Double
        let yDown: Double

        switch orientation {
        case .portrait:
            x = gravity.x
            yDown = -gravity.y
        case .portraitUpsideDown:
            x = -gravity.x
            yDown = gravity.y
        case .landscapeLeft:
            x = gravity.y
            yDown = -gravity.x
        case .landscapeRight:
            x = -gravity.y
            yDown = gravity.x
        default:
            x = gravity.x
            yDown = -gravity.y
        }

        return Float(atan2(x, yDown) * 180.0 / .pi)
    }
}
