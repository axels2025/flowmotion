import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

enum CameraZoomPreset: String, CaseIterable, Identifiable {
    case half
    case one
    case two
    case three

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .half:
            return "0.5x"
        case .one:
            return "1x"
        case .two:
            return "2x"
        case .three:
            return "3x"
        }
    }

    var displayZoomFactor: CGFloat {
        switch self {
        case .half:
            return 0.5
        case .one:
            return 1
        case .two:
            return 2
        case .three:
            return 3
        }
    }
}

enum CameraVideoResolution: String, CaseIterable, Identifiable {
    case hd
    case fourK

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .hd:
            return "HD"
        case .fourK:
            return "4K"
        }
    }

    var targetWidth: Int32 {
        switch self {
        case .hd:
            return 1920
        case .fourK:
            return 3840
        }
    }

    var targetHeight: Int32 {
        switch self {
        case .hd:
            return 1080
        case .fourK:
            return 2160
        }
    }

    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .hd:
            return .hd1920x1080
        case .fourK:
            return .hd4K3840x2160
        }
    }
}

enum CameraFrameRate: Int, CaseIterable, Identifiable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int {
        rawValue
    }

    var title: String {
        "\(rawValue)"
    }

    var time: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(rawValue))
    }
}

enum CameraFlashSetting: String, CaseIterable, Identifiable {
    case on
    case auto
    case off

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .on:
            return "On"
        case .auto:
            return "Auto"
        case .off:
            return "Off"
        }
    }

    var iconName: String {
        switch self {
        case .on:
            return "bolt.fill"
        case .auto:
            return "bolt.badge.a.fill"
        case .off:
            return "bolt.slash.fill"
        }
    }

    var photoFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .on:
            return .on
        case .auto:
            return .auto
        case .off:
            return .off
        }
    }

    var torchMode: AVCaptureDevice.TorchMode {
        switch self {
        case .on:
            return .on
        case .auto:
            return .auto
        case .off:
            return .off
        }
    }
}

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var isAuthorized = false
    @Published private(set) var isSessionRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var statusMessage = "Camera not started"
    @Published private(set) var lastSavedItem = "No media in Photos yet"
    @Published private(set) var videoOrientation: AVCaptureVideoOrientation = .portrait
    @Published private(set) var orientationStatus = "Portrait"
    @Published private(set) var selectedZoomPreset: CameraZoomPreset = .one
    @Published private(set) var zoomStatus = "1x"
    @Published private(set) var selectedVideoResolution: CameraVideoResolution = .hd
    @Published private(set) var selectedFrameRate: CameraFrameRate = .fps30
    @Published private(set) var videoQualityStatus = "HD 30 FPS"
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
    @Published private(set) var flashSetting: CameraFlashSetting = .off
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var actionModeEnabled = false
    @Published private(set) var actionModeAvailable = false

    private let sessionQueue = DispatchQueue(label: "com.flowmotion.camera.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false
    private var currentVideoOrientation: AVCaptureVideoOrientation = .portrait
    private var currentZoomPreset: CameraZoomPreset = .one
    private var currentVideoResolution: CameraVideoResolution = .hd
    private var currentFrameRate: CameraFrameRate = .fps30
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var currentCameraPosition: AVCaptureDevice.Position = .back
    private var currentFlashSetting: CameraFlashSetting = .off
    private var currentExposureBias: Float = 0
    private var currentActionModeEnabled = false
    private var zoomFactorScale: CGFloat = 1

    private struct VideoQualityConfiguration {
        let format: AVCaptureDevice.Format
        let resolution: CameraVideoResolution
        let frameRate: CameraFrameRate
    }

    override init() {
        super.init()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        updateVideoOrientationFromDevice()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    func prepare() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            requestMicrophoneThenConfigure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.requestMicrophoneThenConfigure()
                } else {
                    self.updateMain {
                        self.isAuthorized = false
                        self.statusMessage = "Camera permission denied"
                    }
                }
            }
        case .denied, .restricted:
            updateMain {
                self.isAuthorized = false
                self.statusMessage = "Camera permission denied"
            }
        @unknown default:
            updateMain {
                self.isAuthorized = false
                self.statusMessage = "Camera unavailable"
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            if let videoDevice = self.videoDevice {
                self.setTorchMode(.off, on: videoDevice)
            }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.updateMain {
                self.isSessionRunning = false
            }
        }
    }

    func toggleRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            guard self.isConfigured else {
                self.updateMain {
                    self.statusMessage = "Camera not ready"
                }
                return
            }

            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
                return
            }

            self.applyVideoOrientation(self.currentVideoOrientation)
            let outputURL = self.makeTemporaryMediaURL(extension: "mov")
            self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            guard self.isConfigured else {
                self.updateMain {
                    self.statusMessage = "Camera not ready"
                }
                return
            }

            let settings = AVCapturePhotoSettings()
            if self.videoDevice?.hasFlash == true {
                settings.flashMode = self.currentFlashSetting.photoFlashMode
            } else {
                settings.flashMode = .off
            }
            self.applyVideoOrientation(self.currentVideoOrientation)
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func setZoom(_ preset: CameraZoomPreset) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.currentZoomPreset = preset

            guard self.isConfigured else {
                self.updateMain {
                    self.selectedZoomPreset = preset
                    self.zoomStatus = preset.title
                }
                return
            }

            self.applyZoomPreset(preset)
        }
    }

    func cycleZoom() {
        let presets = CameraZoomPreset.allCases
        let currentIndex = presets.firstIndex(of: currentZoomPreset) ?? 0
        let nextIndex = presets.index(after: currentIndex)
        let nextPreset = nextIndex == presets.endIndex ? presets[0] : presets[nextIndex]
        setZoom(nextPreset)
    }

    func setVideoResolution(_ resolution: CameraVideoResolution) {
        setVideoQuality(resolution: resolution, frameRate: currentFrameRate)
    }

    func setFrameRate(_ frameRate: CameraFrameRate) {
        setVideoQuality(resolution: currentVideoResolution, frameRate: frameRate)
    }

    func setVideoQuality(resolution: CameraVideoResolution, frameRate: CameraFrameRate) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            guard !self.movieOutput.isRecording else {
                self.updateMain {
                    self.statusMessage = "Stop recording to change quality"
                }
                return
            }

            self.currentVideoResolution = resolution
            self.currentFrameRate = frameRate

            guard self.isConfigured else {
                self.updatePublishedQuality(resolution: resolution, frameRate: frameRate)
                return
            }

            self.applyVideoQuality(resolution: resolution, frameRate: frameRate)
        }
    }

    func toggleCameraPosition() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            guard self.isConfigured else {
                self.updateMain {
                    self.statusMessage = "Camera not ready"
                }
                return
            }

            guard !self.movieOutput.isRecording else {
                self.updateMain {
                    self.statusMessage = "Stop recording to switch camera"
                }
                return
            }

            let nextPosition: AVCaptureDevice.Position = self.currentCameraPosition == .back ? .front : .back
            self.switchCamera(to: nextPosition)
        }
    }

    func setFlashSetting(_ setting: CameraFlashSetting) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.currentFlashSetting = setting

            guard self.isConfigured else {
                self.updateMain {
                    self.flashSetting = setting
                }
                return
            }

            self.applyFlashSetting(setting)
        }
    }

    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let requestedBias = min(max(bias, -2), 2)
            self.currentExposureBias = requestedBias

            guard self.isConfigured else {
                self.updateMain {
                    self.exposureBias = requestedBias
                }
                return
            }

            self.applyExposureBias(requestedBias)
        }
    }

    func setActionModeEnabled(_ isEnabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            guard !self.movieOutput.isRecording else {
                self.updateMain {
                    self.statusMessage = "Stop recording to change Action"
                }
                return
            }

            self.currentActionModeEnabled = isEnabled

            guard self.isConfigured else {
                self.updateMain {
                    self.actionModeEnabled = isEnabled
                }
                return
            }

            self.applyActionMode()
        }
    }

    private func requestMicrophoneThenConfigure() {
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        if audioStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.configureAndStart()
            }
            return
        }

        configureAndStart()
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                do {
                    try self.configureSession()
                    self.isConfigured = true
                } catch {
                    self.updateMain {
                        self.isAuthorized = false
                        self.statusMessage = error.localizedDescription
                    }
                    return
                }
            }

            self.applyVideoQuality(resolution: self.currentVideoResolution, frameRate: self.currentFrameRate)

            if !self.session.isRunning {
                self.session.startRunning()
            }

            self.applyVideoOrientation(self.currentVideoOrientation)
            self.updateMain {
                self.isAuthorized = true
                self.isSessionRunning = self.session.isRunning
                self.statusMessage = "Camera ready"
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }

        if session.canSetSessionPreset(currentVideoResolution.sessionPreset) {
            session.sessionPreset = currentVideoResolution.sessionPreset
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        guard let videoDevice = Self.preferredCamera(position: currentCameraPosition) else {
            throw CameraControllerError.cameraUnavailable
        }
        self.videoDevice = videoDevice
        zoomFactorScale = Self.zoomFactorScale(for: videoDevice)

        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(videoInput) else {
            throw CameraControllerError.cannotAddVideoInput
        }
        self.videoInput = videoInput
        session.addInput(videoInput)

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        guard session.canAddOutput(movieOutput) else {
            throw CameraControllerError.cannotAddMovieOutput
        }
        session.addOutput(movieOutput)

        guard session.canAddOutput(photoOutput) else {
            throw CameraControllerError.cannotAddPhotoOutput
        }
        session.addOutput(photoOutput)
        applyVideoOrientation(currentVideoOrientation)
        applyZoomPreset(currentZoomPreset)
        applyFlashSetting(currentFlashSetting)
        applyExposureBias(currentExposureBias)
        applyActionMode()
    }

    private func switchCamera(to position: AVCaptureDevice.Position) {
        guard let nextDevice = Self.preferredCamera(position: position) else {
            updateMain {
                self.statusMessage = position == .front ? "Front camera unavailable" : "Back camera unavailable"
            }
            return
        }

        do {
            let nextInput = try AVCaptureDeviceInput(device: nextDevice)
            if let videoDevice {
                setTorchMode(.off, on: videoDevice)
            }

            session.beginConfiguration()
            let previousInput = videoInput
            if let previousInput {
                session.removeInput(previousInput)
            }

            guard session.canAddInput(nextInput) else {
                if let previousInput, session.canAddInput(previousInput) {
                    session.addInput(previousInput)
                }
                session.commitConfiguration()
                updateMain {
                    self.statusMessage = "Cannot switch camera"
                }
                return
            }

            session.addInput(nextInput)
            session.commitConfiguration()

            videoInput = nextInput
            videoDevice = nextDevice
            currentCameraPosition = position
            zoomFactorScale = Self.zoomFactorScale(for: nextDevice)

            applyVideoQuality(resolution: currentVideoResolution, frameRate: currentFrameRate)
            applyZoomPreset(currentZoomPreset)
            applyFlashSetting(currentFlashSetting)
            applyExposureBias(currentExposureBias)
            applyActionMode()
            applyVideoOrientation(currentVideoOrientation)

            updateMain {
                self.cameraPosition = position
                self.statusMessage = position == .front ? "Front camera" : "Back camera"
            }
        } catch {
            updateMain {
                self.statusMessage = "Camera switch failed: \(error.localizedDescription)"
            }
        }
    }

    private func makeTemporaryMediaURL(extension pathExtension: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "FlowMotion_\(formatter.string(from: Date())).\(pathExtension)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowMotion", isDirectory: true)

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(filename)
    }

    private func requestPhotoLibraryAddAccess(_ completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                completion(newStatus == .authorized || newStatus == .limited)
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func saveVideoToPhotos(_ fileURL: URL) {
        let filename = fileURL.lastPathComponent
        requestPhotoLibraryAddAccess { [weak self] granted in
            guard let self else { return }

            guard granted else {
                self.updateMain {
                    self.statusMessage = "Photos permission denied"
                    self.lastSavedItem = "Enable Photos access to save \(filename)"
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = filename

                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: fileURL, options: options)
            } completionHandler: { success, error in
                if success {
                    try? FileManager.default.removeItem(at: fileURL)
                }

                self.updateMain {
                    if success {
                        self.statusMessage = "Video saved to Photos"
                        self.lastSavedItem = filename
                    } else {
                        self.statusMessage = "Photos save failed: \(error?.localizedDescription ?? "Unknown error")"
                        self.lastSavedItem = filename
                    }
                }
            }
        }
    }

    private func savePhotoToPhotos(_ data: Data, filename: String) {
        requestPhotoLibraryAddAccess { [weak self] granted in
            guard let self else { return }

            guard granted else {
                self.updateMain {
                    self.statusMessage = "Photos permission denied"
                    self.lastSavedItem = "Enable Photos access to save \(filename)"
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = filename

                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: options)
            } completionHandler: { success, error in
                self.updateMain {
                    if success {
                        self.statusMessage = "Photo saved to Photos"
                        self.lastSavedItem = filename
                    } else {
                        self.statusMessage = "Photos save failed: \(error?.localizedDescription ?? "Unknown error")"
                        self.lastSavedItem = filename
                    }
                }
            }
        }
    }

    private func updateMain(_ update: @escaping () -> Void) {
        DispatchQueue.main.async(execute: update)
    }

    @objc private func deviceOrientationDidChange() {
        updateVideoOrientationFromDevice()
    }

    private func updateVideoOrientationFromDevice() {
        guard let orientation = AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation) else {
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.currentVideoOrientation = orientation
            self.applyVideoOrientation(orientation)
            self.updateMain {
                self.videoOrientation = orientation
                self.orientationStatus = orientation.flowMotionTitle
            }
        }
    }

    private func applyVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        if let connection = movieOutput.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }

        if let connection = photoOutput.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }
    }

    private func applyFlashSetting(_ setting: CameraFlashSetting) {
        guard let videoDevice else {
            updateMain {
                self.flashSetting = setting
            }
            return
        }

        if videoDevice.hasTorch, videoDevice.isTorchModeSupported(setting.torchMode) {
            setTorchMode(setting.torchMode, on: videoDevice)
        } else if setting == .on {
            updateMain {
                self.statusMessage = "Light unavailable on this camera"
            }
        }

        updateMain {
            self.flashSetting = setting
        }
    }

    private func setTorchMode(_ mode: AVCaptureDevice.TorchMode, on device: AVCaptureDevice) {
        guard device.hasTorch, device.isTorchModeSupported(mode) else {
            return
        }

        do {
            try device.lockForConfiguration()
            device.torchMode = mode
            device.unlockForConfiguration()
        } catch {
            updateMain {
                self.statusMessage = "Light failed: \(error.localizedDescription)"
            }
        }
    }

    private func applyExposureBias(_ bias: Float) {
        guard let videoDevice else {
            updateMain {
                self.exposureBias = bias
            }
            return
        }

        let clampedBias = min(
            max(bias, max(videoDevice.minExposureTargetBias, -2)),
            min(videoDevice.maxExposureTargetBias, 2)
        )

        do {
            try videoDevice.lockForConfiguration()
            if videoDevice.isExposureModeSupported(.continuousAutoExposure) {
                videoDevice.exposureMode = .continuousAutoExposure
            }
            videoDevice.setExposureTargetBias(clampedBias, completionHandler: nil)
            videoDevice.unlockForConfiguration()
            currentExposureBias = clampedBias
            updateMain {
                self.exposureBias = clampedBias
            }
        } catch {
            updateMain {
                self.statusMessage = "Exposure failed: \(error.localizedDescription)"
            }
        }
    }

    private func applyActionMode() {
        guard let connection = movieOutput.connection(with: .video),
              connection.isVideoStabilizationSupported,
              let videoDevice else {
            currentActionModeEnabled = false
            updateMain {
                self.actionModeAvailable = false
                self.actionModeEnabled = false
            }
            return
        }

        let preferredMode = Self.preferredActionStabilizationMode(for: videoDevice.activeFormat)
        let isAvailable = preferredMode != nil

        guard currentActionModeEnabled, let preferredMode else {
            connection.preferredVideoStabilizationMode = .off
            updateMain {
                self.actionModeAvailable = isAvailable
                self.actionModeEnabled = false
            }
            return
        }

        connection.preferredVideoStabilizationMode = preferredMode
        updateMain {
            self.actionModeAvailable = true
            self.actionModeEnabled = true
        }
    }

    private func applyZoomPreset(_ preset: CameraZoomPreset) {
        guard let videoDevice else {
            updateMain {
                self.selectedZoomPreset = preset
                self.zoomStatus = preset.title
            }
            return
        }

        let requestedFactor = preset.displayZoomFactor * zoomFactorScale
        let clampedFactor = min(
            max(requestedFactor, videoDevice.minAvailableVideoZoomFactor),
            min(videoDevice.maxAvailableVideoZoomFactor, 12)
        )

        do {
            try videoDevice.lockForConfiguration()
            videoDevice.videoZoomFactor = clampedFactor
            videoDevice.unlockForConfiguration()

            let didClamp = abs(clampedFactor - requestedFactor) > 0.01
            let status = didClamp ? "\(preset.title) unavailable" : preset.title
            updateMain {
                self.selectedZoomPreset = preset
                self.zoomStatus = status
            }
        } catch {
            updateMain {
                self.statusMessage = "Zoom failed: \(error.localizedDescription)"
                self.selectedZoomPreset = preset
                self.zoomStatus = "Zoom unavailable"
            }
        }
    }

    private func applyVideoQuality(resolution: CameraVideoResolution, frameRate: CameraFrameRate) {
        guard let videoDevice else {
            updatePublishedQuality(resolution: resolution, frameRate: frameRate)
            return
        }

        guard let configuration = Self.bestQualityConfiguration(
            for: videoDevice,
            requestedResolution: resolution,
            requestedFrameRate: frameRate
        ) else {
            applyPresetFallback(resolution: resolution, frameRate: frameRate)
            return
        }

        var didLockDevice = false
        do {
            session.beginConfiguration()
            if session.canSetSessionPreset(.inputPriority) {
                session.sessionPreset = .inputPriority
            } else if session.canSetSessionPreset(configuration.resolution.sessionPreset) {
                session.sessionPreset = configuration.resolution.sessionPreset
            }

            try videoDevice.lockForConfiguration()
            didLockDevice = true
            videoDevice.activeFormat = configuration.format
            videoDevice.activeVideoMinFrameDuration = configuration.frameRate.time
            videoDevice.activeVideoMaxFrameDuration = configuration.frameRate.time
            videoDevice.unlockForConfiguration()
            didLockDevice = false
            session.commitConfiguration()

            currentVideoResolution = configuration.resolution
            currentFrameRate = configuration.frameRate
            updatePublishedQuality(
                resolution: configuration.resolution,
                frameRate: configuration.frameRate,
                fallbackFrom: configuration.resolution == resolution && configuration.frameRate == frameRate ? nil : (resolution, frameRate)
            )
            applyZoomPreset(currentZoomPreset)
            applyExposureBias(currentExposureBias)
            applyActionMode()
        } catch {
            if didLockDevice {
                videoDevice.unlockForConfiguration()
            }
            session.commitConfiguration()
            updateMain {
                self.statusMessage = "Quality failed: \(error.localizedDescription)"
            }
        }
    }

    private func applyPresetFallback(resolution: CameraVideoResolution, frameRate: CameraFrameRate) {
        session.beginConfiguration()
        if session.canSetSessionPreset(resolution.sessionPreset) {
            session.sessionPreset = resolution.sessionPreset
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        session.commitConfiguration()

        let appliedResolution: CameraVideoResolution = session.sessionPreset == .hd4K3840x2160 ? .fourK : .hd
        currentVideoResolution = appliedResolution
        currentFrameRate = .fps30
        updatePublishedQuality(
            resolution: appliedResolution,
            frameRate: .fps30,
            fallbackFrom: (resolution, frameRate)
        )
        applyZoomPreset(currentZoomPreset)
        applyExposureBias(currentExposureBias)
        applyActionMode()
    }

    private func updatePublishedQuality(
        resolution: CameraVideoResolution,
        frameRate: CameraFrameRate,
        fallbackFrom requestedQuality: (CameraVideoResolution, CameraFrameRate)? = nil
    ) {
        let status = "\(resolution.title) \(frameRate.title) FPS"
        updateMain {
            self.selectedVideoResolution = resolution
            self.selectedFrameRate = frameRate
            self.videoQualityStatus = status

            if let requestedQuality {
                self.statusMessage = "\(requestedQuality.0.title) \(requestedQuality.1.title) unavailable; using \(status)"
            }
        }
    }

    private static func bestQualityConfiguration(
        for device: AVCaptureDevice,
        requestedResolution: CameraVideoResolution,
        requestedFrameRate: CameraFrameRate
    ) -> VideoQualityConfiguration? {
        let preferences: [(CameraVideoResolution, CameraFrameRate)] = [
            (requestedResolution, requestedFrameRate),
            (requestedResolution, .fps30),
            (.hd, requestedFrameRate),
            (.hd, .fps30),
            (.hd, .fps24)
        ]

        var seen: Set<String> = []
        for preference in preferences {
            let key = "\(preference.0.rawValue)-\(preference.1.rawValue)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            if let format = bestFormat(
                for: device,
                resolution: preference.0,
                frameRate: preference.1
            ) {
                return VideoQualityConfiguration(
                    format: format,
                    resolution: preference.0,
                    frameRate: preference.1
                )
            }
        }

        return nil
    }

    private static func bestFormat(
        for device: AVCaptureDevice,
        resolution: CameraVideoResolution,
        frameRate: CameraFrameRate
    ) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { format in
            formatMatches(format, resolution: resolution)
                && formatSupports(format, frameRate: frameRate)
        }

        return candidates.sorted { left, right in
            let leftDimensions = normalizedDimensions(for: left)
            let rightDimensions = normalizedDimensions(for: right)
            let leftDistance = abs(Int(leftDimensions.width - resolution.targetWidth))
                + abs(Int(leftDimensions.height - resolution.targetHeight))
            let rightDistance = abs(Int(rightDimensions.width - resolution.targetWidth))
                + abs(Int(rightDimensions.height - resolution.targetHeight))

            if leftDistance != rightDistance {
                return leftDistance < rightDistance
            }

            return maxFrameRate(for: left) > maxFrameRate(for: right)
        }.first
    }

    private static func formatMatches(_ format: AVCaptureDevice.Format, resolution: CameraVideoResolution) -> Bool {
        let dimensions = normalizedDimensions(for: format)

        switch resolution {
        case .hd:
            return dimensions.width == resolution.targetWidth
                && dimensions.height == resolution.targetHeight
        case .fourK:
            return dimensions.width >= resolution.targetWidth
                && dimensions.height >= resolution.targetHeight
        }
    }

    private static func formatSupports(_ format: AVCaptureDevice.Format, frameRate: CameraFrameRate) -> Bool {
        let requestedFPS = Double(frameRate.rawValue)
        return format.videoSupportedFrameRateRanges.contains { range in
            range.minFrameRate <= requestedFPS && requestedFPS <= range.maxFrameRate
        }
    }

    private static func normalizedDimensions(for format: AVCaptureDevice.Format) -> (width: Int32, height: Int32) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return (
            width: max(dimensions.width, dimensions.height),
            height: min(dimensions.width, dimensions.height)
        )
    }

    private static func maxFrameRate(for format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges
            .map(\.maxFrameRate)
            .max() ?? 0
    }

    private static func preferredCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType]
        switch position {
        case .front:
            preferredTypes = [
                .builtInTrueDepthCamera,
                .builtInWideAngleCamera
            ]
        default:
            preferredTypes = [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera,
                .builtInUltraWideCamera
            ]
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredTypes,
            mediaType: .video,
            position: position
        )

        for type in preferredTypes {
            if let device = discoverySession.devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }

        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    private static func preferredActionStabilizationMode(for format: AVCaptureDevice.Format) -> AVCaptureVideoStabilizationMode? {
        if #available(iOS 18.0, *),
           format.isVideoStabilizationModeSupported(.cinematicExtendedEnhanced) {
            return .cinematicExtendedEnhanced
        }

        if format.isVideoStabilizationModeSupported(.cinematicExtended) {
            return .cinematicExtended
        }

        if format.isVideoStabilizationModeSupported(.cinematic) {
            return .cinematic
        }

        if format.isVideoStabilizationModeSupported(.standard) {
            return .standard
        }

        return nil
    }

    private static func zoomFactorScale(for device: AVCaptureDevice) -> CGFloat {
        switch device.deviceType {
        case .builtInTripleCamera, .builtInDualWideCamera, .builtInUltraWideCamera:
            return 2
        default:
            return 1
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        updateMain {
            self.isRecording = true
            self.statusMessage = "Recording"
            self.lastSavedItem = "Recording \(fileURL.lastPathComponent)"
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        updateMain {
            self.isRecording = false
            if let error {
                self.statusMessage = "Recording failed: \(error.localizedDescription)"
            } else {
                self.statusMessage = "Saving video to Photos"
                self.lastSavedItem = outputFileURL.lastPathComponent
            }
        }

        if error == nil {
            saveVideoToPhotos(outputFileURL)
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            updateMain {
                self.statusMessage = "Photo failed: \(error.localizedDescription)"
            }
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            updateMain {
                self.statusMessage = "Photo data unavailable"
            }
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "FlowMotion_\(formatter.string(from: Date())).jpg"

        updateMain {
            self.statusMessage = "Saving photo to Photos"
            self.lastSavedItem = filename
        }
        savePhotoToPhotos(data, filename: filename)
    }
}

enum CameraControllerError: LocalizedError {
    case cameraUnavailable
    case cannotAddVideoInput
    case cannotAddMovieOutput
    case cannotAddPhotoOutput

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "Back camera unavailable"
        case .cannotAddVideoInput:
            return "Cannot add camera input"
        case .cannotAddMovieOutput:
            return "Cannot add video recorder"
        case .cannotAddPhotoOutput:
            return "Cannot add photo capture"
        }
    }
}

extension AVCaptureVideoOrientation {
    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait:
            self = .portrait
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        case .landscapeLeft:
            self = .landscapeRight
        case .landscapeRight:
            self = .landscapeLeft
        case .faceUp, .faceDown, .unknown:
            return nil
        @unknown default:
            return nil
        }
    }

    var flowMotionTitle: String {
        switch self {
        case .portrait:
            return "Portrait"
        case .portraitUpsideDown:
            return "Portrait Upside Down"
        case .landscapeLeft:
            return "Landscape Left"
        case .landscapeRight:
            return "Landscape Right"
        @unknown default:
            return "Unknown"
        }
    }
}
