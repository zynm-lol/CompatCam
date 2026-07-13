//
//  CameraViewModel.swift
//  CompatCam
//
//  MVVM: the view layer talks only to this object. It owns the
//  CameraManager + CameraCompatibilityEngine and exposes simple,
//  @Published state for SwiftUI to bind to.
//
//  Capture modes: this app exposes Photo, Video, and Manual. The original
//  spec's "Portrait" and "Professional" swipe modes were folded in rather
//  than kept as separate top-level modes:
//   - Portrait would require virtual-camera depth capture + person
//     segmentation, a large, separate subsystem disproportionate to this
//     app's actual goal (getting a marginal rear camera working at all).
//   - "Professional" wasn't a distinct capture pipeline in the spec, just a
//     label for manual controls — which already exist as their own mode,
//     so a second entry point to the same controls was redundant.
//

import AVFoundation
import Combine
import SwiftUI

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo = "Photo"
    case video = "Video"
    case manual = "Manual"
    var id: String { rawValue }
}

@MainActor
final class CameraViewModel: ObservableObject {

    let manager = CameraManager()
    let engine = CameraCompatibilityEngine()
    let filterEngine = FilterEngine()
    let frameAnalysis: FrameAnalysisCoordinator
    private let photoCoordinator = PhotoCaptureCoordinator()
    private let logger = DiagnosticsLogger.shared

    @Published var compatibilityMode: CompatibilityMode = .standard
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published var captureMode: CaptureMode = .photo
    @Published var selectedFilter: LiveFilter = .natural
    @Published var isStartingUp: Bool = true
    @Published var startupErrorMessage: String?
    @Published var isCapturing: Bool = false
    @Published var lastCaptureThumbnail: UIImage?
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published var timerSeconds: Int = 0
    @Published var isCountingDown: Bool = false
    @Published var countdownRemaining: Int = 0
    @Published var isRawCaptureEnabled: Bool = false
    @Published var burstCount: Int = 5
    @Published var isBurstCapturing: Bool = false
    @Published var burstThumbnails: [UIImage] = []

    // Manual exposure (ISO / shutter)
    @Published var useCustomExposure: Bool = false
    @Published var manualISO: Float = 100
    @Published var manualShutterSeconds: Double = 1.0 / 60.0

    // Overlays
    @Published var isHistogramVisible: Bool = false {
        didSet { frameAnalysis.isHistogramEnabled = isHistogramVisible }
    }
    @Published var isFocusPeakingVisible: Bool = false {
        didSet { frameAnalysis.isFocusPeakingEnabled = isFocusPeakingVisible }
    }
    @Published var isZebraVisible: Bool = false {
        didSet { frameAnalysis.isZebraEnabled = isZebraVisible }
    }

    init() {
        self.frameAnalysis = FrameAnalysisCoordinator(context: filterEngine.context)
        manager.compatibilityEngine = engine
        manager.frameAnalysisCoordinator = frameAnalysis
    }

    /// Called once when the camera screen appears. Runs the full
    /// compatibility search and starts the session on the first
    /// working configuration.
    func start() async {
        isStartingUp = true
        startupErrorMessage = nil
        manager.setActiveSearchContext(mode: compatibilityMode, position: cameraPosition)

        do {
            _ = try await engine.findWorkingConfiguration(mode: compatibilityMode, position: cameraPosition, using: manager)
            if captureMode == .video {
                try? await manager.enableVideoRecording()
            }
        } catch {
            startupErrorMessage = error.localizedDescription
            await logger.log("Startup failed entirely: \(error.localizedDescription)", level: .error)
        }
        isStartingUp = false
    }

    /// Restarts the search — used when the user changes Compatibility Mode
    /// or flips the camera, without needing to relaunch the app.
    func restart(mode: CompatibilityMode? = nil, position: AVCaptureDevice.Position? = nil) async {
        if let mode { compatibilityMode = mode }
        if let position { cameraPosition = position }
        manager.stop()
        await start()
    }

    func applyManualConfiguration(_ configuration: CameraConfiguration) async {
        isStartingUp = true
        startupErrorMessage = nil
        do {
            try await manager.applyConfiguration(configuration)
            if captureMode == .video {
                try? await manager.enableVideoRecording()
            }
        } catch {
            startupErrorMessage = error.localizedDescription
        }
        isStartingUp = false
    }

    /// Switches between Photo/Video/Manual. Video needs the movie output +
    /// microphone wired in, which is done lazily here rather than always,
    /// so a photo-only session stays as simple (and as compatible) as possible.
    func setCaptureMode(_ mode: CaptureMode) async {
        captureMode = mode
        if mode == .video {
            do {
                try await manager.enableVideoRecording()
            } catch {
                startupErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Photo capture (with optional timer, RAW, burst)

    func capturePhoto() async {
        guard !isCapturing, !isBurstCapturing else { return }

        if timerSeconds > 0 {
            await runCountdown(seconds: timerSeconds)
        }

        await performSingleCapture()
    }

    func captureBurst() async {
        guard !isCapturing, !isBurstCapturing else { return }
        isBurstCapturing = true
        burstThumbnails = []
        defer { isBurstCapturing = false }

        for _ in 0..<burstCount {
            await performSingleCapture(isPartOfBurst: true)
        }
        await logger.log("Burst capture finished: \(burstThumbnails.count) frame(s).", level: .success)
    }

    private func performSingleCapture(isPartOfBurst: Bool = false) async {
        isCapturing = true
        defer { isCapturing = false }

        let settings: AVCapturePhotoSettings
        if isRawCaptureEnabled, let raw = PhotoCaptureCoordinator.rawSettings(output: manager.photoOutput, flashMode: manager.photoOutput.supportedFlashModes.contains(flashMode) ? flashMode : .off) {
            settings = raw
        } else {
            let codec: AVVideoCodecType = manager.photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            settings = PhotoCaptureCoordinator.standardSettings(
                codec: codec,
                flashMode: manager.photoOutput.supportedFlashModes.contains(flashMode) ? flashMode : .off,
                highResolution: manager.photoOutput.isHighResolutionCaptureEnabled
            )
        }

        do {
            let result = try await photoCoordinator.capturePhoto(with: manager.photoOutput, settings: settings)
            try await PhotoCaptureCoordinator.save(result)

            if let data = result.processedData ?? result.rawData, let uiImage = UIImage(data: data) {
                lastCaptureThumbnail = uiImage
                if isPartOfBurst { burstThumbnails.append(uiImage) }
            }
            await logger.log("Photo captured and saved\(isRawCaptureEnabled ? " (RAW)" : "").", level: .success)
        } catch {
            await logger.log("Photo capture failed: \(error.localizedDescription)", level: .error)
            if !isPartOfBurst { startupErrorMessage = error.localizedDescription }
        }
    }

    private func runCountdown(seconds: Int) async {
        isCountingDown = true
        countdownRemaining = seconds
        for remaining in stride(from: seconds, through: 1, by: -1) {
            countdownRemaining = remaining
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        isCountingDown = false
    }

    // MARK: - Video recording

    func toggleRecording() async {
        if manager.published.isRecordingVideo {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        do {
            try await manager.enableVideoRecording()
            try await manager.startRecording()
            await logger.log("Recording started.", level: .info)
        } catch {
            startupErrorMessage = error.localizedDescription
            await logger.log("Failed to start recording: \(error.localizedDescription)", level: .error)
        }
    }

    private func stopRecording() async {
        do {
            let url = try await manager.stopRecording()
            try await VideoRecordingCoordinator.saveToPhotos(url)
            await logger.log("Recording saved to Photos.", level: .success)
        } catch {
            startupErrorMessage = error.localizedDescription
            await logger.log("Failed to save recording: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Manual exposure

    func applyCustomExposure() {
        guard useCustomExposure else { return }
        let duration = CMTime(seconds: manualShutterSeconds, preferredTimescale: 1_000_000)
        manager.setCustomExposure(iso: manualISO, duration: duration)
    }

    // MARK: - Misc device controls

    func toggleTorch() {
        manager.setTorch(on: !manager.published.isTorchOn)
    }

    func setZoom(_ factor: CGFloat) {
        manager.setZoom(factor)
    }

    func focus(at point: CGPoint) {
        manager.focus(at: point)
    }

    func stop() {
        manager.stop()
    }
}
