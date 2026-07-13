//
//  CameraManager.swift
//  CompatCam
//
//  Owns the single AVCaptureSession for the app. All mutation of the
//  session happens on a dedicated serial queue (never the main thread),
//  matching Apple's AVFoundation threading guidance. Public state is
//  mirrored to a @MainActor ObservableObject for SwiftUI.
//
//  This class is deliberately defensive: every device/format/input/output
//  operation is wrapped so that failures throw typed errors instead of
//  crashing, which is what allows the CompatibilityEngine to retry safely.
//

import AVFoundation
import Combine
import Foundation
import UIKit

enum CameraManagerError: LocalizedError {
    case deviceNotFound(deviceTypes: [AVCaptureDevice.DeviceType], position: AVCaptureDevice.Position)
    case cannotAddInput
    case cannotAddPhotoOutput
    case cannotAddVideoOutput
    case lockForConfigurationFailed(underlying: Error)
    case sessionNotRunningAfterStart
    case unsupportedFormat
    case cannotAddMovieOutput
    case cannotAddAudioInput
    case noAudioDeviceAvailable
    case customExposureUnsupported
    case rawCaptureUnsupported

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let types, let position):
            return "No device matching \(types) at position \(position.rawValue)."
        case .cannotAddInput:
            return "Capture session refused the device input."
        case .cannotAddPhotoOutput:
            return "Capture session refused the photo output."
        case .cannotAddVideoOutput:
            return "Capture session refused the video data output."
        case .lockForConfigurationFailed(let underlying):
            return "Could not lock device for configuration: \(underlying.localizedDescription)"
        case .sessionNotRunningAfterStart:
            return "Session did not report isRunning == true after startRunning()."
        case .unsupportedFormat:
            return "No format on this device satisfied the requested selector."
        case .cannotAddMovieOutput:
            return "Capture session refused the movie file output."
        case .cannotAddAudioInput:
            return "Capture session refused the microphone input."
        case .noAudioDeviceAvailable:
            return "No microphone was found for video recording."
        case .customExposureUnsupported:
            return "This device does not support custom (manual) exposure."
        case .rawCaptureUnsupported:
            return "This device/format combination does not support RAW capture."
        }
    }
}

/// Everything the SwiftUI layer needs to observe, kept on the main actor.
@MainActor
final class CameraManagerPublishedState: ObservableObject {
    @Published var sessionState: SessionState = .notStarted
    @Published var currentConfiguration: CameraConfiguration?
    @Published var currentDevice: AVCaptureDevice?
    @Published var lastError: String?
    @Published var isTorchOn: Bool = false
    @Published var currentZoomFactor: CGFloat = 1.0
    @Published var isRecordingVideo: Bool = false
    @Published var recordingElapsedSeconds: Int = 0
    @Published var isRawCaptureAvailable: Bool = false
    @Published var supportsCustomExposure: Bool = false
    @Published var currentISORange: ClosedRange<Float> = 0...100
    @Published var currentDurationRange: ClosedRange<CMTime> = CMTime(value: 1, timescale: 1000)...CMTime(value: 1, timescale: 30)
}

final class CameraManager: NSObject {

    let session = AVCaptureSession()
    let published = CameraManagerPublishedState()

    let photoOutput = AVCapturePhotoOutput()
    let videoDataOutput = AVCaptureVideoDataOutput()
    let movieFileOutput = AVCaptureMovieFileOutput()

    /// Wired up lazily once we know which Metal/CIContext the filter engine
    /// is using, so histogram/peaking/zebra share the same rendering context.
    var frameAnalysisCoordinator: FrameAnalysisCoordinator? {
        didSet {
            videoDataOutput.setSampleBufferDelegate(frameAnalysisCoordinator, queue: analysisDelegateQueue)
        }
    }
    private let analysisDelegateQueue = DispatchQueue(label: "com.compatcam.frameAnalysisDelegate", qos: .utility)

    /// Whether the session is currently wired for video recording (adds
    /// the movie file output + microphone) vs. photo-only. Switching this
    /// requires re-running `configureSession`, which happens automatically
    /// the next time `applyConfiguration` or `setCaptureMode` runs.
    private(set) var isConfiguredForVideo = false
    private var audioInput: AVCaptureDeviceInput?
    private var videoRecordingCoordinator: VideoRecordingCoordinator?

    /// Serial queue used for ALL session mutation and device I/O, per
    /// Apple's AVFoundation guidance (never touch AVCaptureSession from
    /// arbitrary threads).
    private let sessionQueue = DispatchQueue(label: "com.compatcam.sessionQueue", qos: .userInitiated)

    private var currentInput: AVCaptureDeviceInput?
    private var interruptionObserver: NSObjectProtocol?
    private var runtimeErrorObserver: NSObjectProtocol?
    private let logger = DiagnosticsLogger.shared

    /// Weak reference so the engine can be asked to recover without a retain cycle.
    weak var compatibilityEngine: CameraCompatibilityEngine?
    private var activeMode: CompatibilityMode = .standard
    private var activePosition: AVCaptureDevice.Position = .back

    override init() {
        super.init()
        observeInterruptions()
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let runtimeErrorObserver { NotificationCenter.default.removeObserver(runtimeErrorObserver) }
    }

    // MARK: - Public API

    func setActiveSearchContext(mode: CompatibilityMode, position: AVCaptureDevice.Position) {
        activeMode = mode
        activePosition = position
    }

    /// Discovers a device, builds inputs/outputs, and starts the session
    /// according to `configuration`. Throws immediately (without leaving the
    /// session half-configured) if any step fails, so the engine can safely
    /// try the next candidate.
    func applyConfiguration(_ configuration: CameraConfiguration) async throws {
        await MainActor.run { self.published.sessionState = .discoveringDevice }

        let device = try discoverDevice(configuration: configuration)

        await MainActor.run { self.published.sessionState = .configuring }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.configureSession(device: device, configuration: configuration)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        try await startSessionAndVerify()

        let rawAvailable = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        let customExposureAvailable = device.isExposureModeSupported(.custom)
        let isoRange = device.activeFormat.minISO...device.activeFormat.maxISO
        let durationRange = device.activeFormat.minExposureDuration...device.activeFormat.maxExposureDuration

        await MainActor.run {
            self.published.sessionState = .running
            self.published.currentConfiguration = configuration
            self.published.currentDevice = device
            self.published.lastError = nil
            self.published.isRawCaptureAvailable = rawAvailable
            self.published.supportsCustomExposure = customExposureAvailable
            self.published.currentISORange = isoRange
            self.published.currentDurationRange = durationRange
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let clamped = max(device.minAvailableVideoZoomFactor, min(factor, device.maxAvailableVideoZoomFactor))
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                Task { @MainActor in self.published.currentZoomFactor = clamped }
            } catch {
                Task { await self.logger.log("Zoom failed: \(error.localizedDescription)", level: .warning) }
            }
        }
    }

    func setTorch(on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
                Task { @MainActor in self.published.isTorchOn = on }
            } catch {
                Task { await self.logger.log("Torch toggle failed: \(error.localizedDescription)", level: .warning) }
            }
        }
    }

    func focus(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                Task { await self.logger.log("Tap-to-focus failed: \(error.localizedDescription)", level: .warning) }
            }
        }
    }

    /// Adds (or confirms) the audio input + movie file output needed for
    /// video recording. Safe to call repeatedly; a no-op if already wired.
    func enableVideoRecording() async throws {
        guard !isConfiguredForVideo else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.session.beginConfiguration()
                defer { self.session.commitConfiguration() }

                do {
                    if self.audioInput == nil {
                        guard let micDevice = AVCaptureDevice.default(for: .audio) else {
                            throw CameraManagerError.noAudioDeviceAvailable
                        }
                        let micInput = try AVCaptureDeviceInput(device: micDevice)
                        guard self.session.canAddInput(micInput) else {
                            throw CameraManagerError.cannotAddAudioInput
                        }
                        self.session.addInput(micInput)
                        self.audioInput = micInput
                    }

                    guard self.session.canAddOutput(self.movieFileOutput) else {
                        throw CameraManagerError.cannotAddMovieOutput
                    }
                    if !self.session.outputs.contains(self.movieFileOutput) {
                        self.session.addOutput(self.movieFileOutput)
                    }
                    if let connection = self.movieFileOutput.connection(with: .video),
                       connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .auto
                    }

                    self.isConfiguredForVideo = true
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        await logger.log("Video recording capability enabled (audio input + movie output).", level: .info)
    }

    /// Starts recording to a temporary file and returns once recording has
    /// actually begun writing (not once it finishes — see `stopRecording`).
    func startRecording() async throws {
        if videoRecordingCoordinator == nil {
            videoRecordingCoordinator = VideoRecordingCoordinator()
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        await MainActor.run {
            self.published.isRecordingVideo = true
            self.published.recordingElapsedSeconds = 0
        }
        videoRecordingCoordinator?.beginTracking { [weak self] elapsed in
            Task { @MainActor in self?.published.recordingElapsedSeconds = elapsed }
        }
        videoRecordingCoordinator?.startRecording(output: movieFileOutput, to: tempURL)
    }

    /// Stops recording and returns the local file URL of the finished movie.
    @discardableResult
    func stopRecording() async throws -> URL {
        defer {
            Task { @MainActor in
                self.published.isRecordingVideo = false
                self.published.recordingElapsedSeconds = 0
            }
        }
        guard let coordinator = videoRecordingCoordinator else {
            throw CameraManagerError.cannotAddMovieOutput
        }
        return try await coordinator.stopRecording(output: movieFileOutput)
    }

    /// Manual exposure: sets a fixed ISO + shutter duration if the active
    /// device supports `.custom` exposure mode.
    func setCustomExposure(iso: Float, duration: CMTime) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            guard device.isExposureModeSupported(.custom) else {
                Task { await self.logger.log("Custom exposure requested but unsupported on this device.", level: .warning) }
                return
            }
            do {
                try device.lockForConfiguration()
                let clampedISO = max(device.activeFormat.minISO, min(iso, device.activeFormat.maxISO))
                let minDuration = device.activeFormat.minExposureDuration
                let maxDuration = device.activeFormat.maxExposureDuration
                let clampedDuration = max(minDuration, min(duration, maxDuration))
                device.setExposureModeCustom(duration: clampedDuration, iso: clampedISO, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                Task { await self.logger.log("Custom exposure failed: \(error.localizedDescription)", level: .warning) }
            }
        }
    }

    // MARK: - Device discovery (public APIs only)

    private func discoverDevice(configuration: CameraConfiguration) throws -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: configuration.deviceTypes,
            mediaType: .video,
            position: configuration.position
        )

        guard let device = discovery.devices.first else {
            throw CameraManagerError.deviceNotFound(deviceTypes: configuration.deviceTypes, position: configuration.position)
        }
        return device
    }

    // MARK: - Session configuration

    private func configureSession(device: AVCaptureDevice, configuration: CameraConfiguration) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Remove anything from a previous (failed or different) configuration.
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        // A full reconfiguration wipes the movie output + mic input too, so
        // reset this flag; the ViewModel re-calls enableVideoRecording()
        // after a mode switch/restart if the user is in Video mode.
        isConfiguredForVideo = false
        audioInput = nil

        if session.canSetSessionPreset(configuration.sessionPreset) {
            session.sessionPreset = configuration.sessionPreset
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraManagerError.lockForConfigurationFailed(underlying: error)
        }

        guard session.canAddInput(input) else {
            throw CameraManagerError.cannotAddInput
        }
        session.addInput(input)
        currentInput = input

        guard session.canAddOutput(photoOutput) else {
            throw CameraManagerError.cannotAddPhotoOutput
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = configuration.wantsHighResolutionCapture ? .quality : .balanced

        guard session.canAddOutput(videoDataOutput) else {
            throw CameraManagerError.cannotAddVideoOutput
        }
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        session.addOutput(videoDataOutput)

        try applyFormat(to: device, configuration: configuration)
        try applyDeviceModes(to: device, configuration: configuration)
        applyConnectionSettings(configuration: configuration)
    }

    private func applyFormat(to device: AVCaptureDevice, configuration: CameraConfiguration) throws {
        guard configuration.preferredFormatSelector != .deviceDefault else { return }

        let candidateFormats = device.formats

        let chosen: AVCaptureDevice.Format?
        switch configuration.preferredFormatSelector {
        case .deviceDefault:
            chosen = nil
        case .highestResolution:
            chosen = candidateFormats.max { lhs, rhs in
                let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                return (Int64(l.width) * Int64(l.height)) < (Int64(r.width) * Int64(r.height))
            }
        case .lowestResolution:
            chosen = candidateFormats.min { lhs, rhs in
                let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                return (Int64(l.width) * Int64(l.height)) < (Int64(r.width) * Int64(r.height))
            }
        case .closestTo(let width, let height):
            chosen = candidateFormats.min { lhs, rhs in
                let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                let lDelta = abs(Int64(l.width) - Int64(width)) + abs(Int64(l.height) - Int64(height))
                let rDelta = abs(Int64(r.width) - Int64(width)) + abs(Int64(r.height) - Int64(height))
                return lDelta < rDelta
            }
        case .mustSupportFrameRate(let fps):
            chosen = candidateFormats.first {
                $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps && $0.minFrameRate <= fps }
            }
        }

        guard let chosen else { throw CameraManagerError.unsupportedFormat }

        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            device.unlockForConfiguration()
        } catch {
            throw CameraManagerError.lockForConfigurationFailed(underlying: error)
        }
    }

    private func applyDeviceModes(to device: AVCaptureDevice, configuration: CameraConfiguration) throws {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusModeSupported(configuration.autofocusMode) {
                device.focusMode = configuration.autofocusMode
            }
            if device.isExposureModeSupported(configuration.exposureMode) {
                device.exposureMode = configuration.exposureMode
            }
            if device.isWhiteBalanceModeSupported(configuration.whiteBalanceMode) {
                device.whiteBalanceMode = configuration.whiteBalanceMode
            }
        } catch {
            throw CameraManagerError.lockForConfigurationFailed(underlying: error)
        }
    }

    private func applyConnectionSettings(configuration: CameraConfiguration) {
        guard let connection = photoOutput.connection(with: .video) else { return }

        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = configuration.stabilizationMode
        }

        if #available(iOS 17.0, *), photoOutput.isAutoDeferredPhotoDeliverySupported {
            photoOutput.isAutoDeferredPhotoDeliveryEnabled = false // keep default synchronous pipeline for reliability
        }

        photoOutput.isHighResolutionCaptureEnabled = configuration.wantsHighResolutionCapture
    }

    // MARK: - Start + verify

    private func startSessionAndVerify() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                // Give the hardware a brief moment to actually spin up before
                // declaring victory — startRunning() is asynchronous internally.
                self.sessionQueue.asyncAfter(deadline: .now() + 0.35) {
                    if self.session.isRunning {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: CameraManagerError.sessionNotRunningAfterStart)
                    }
                }
            }
        }
    }

    // MARK: - Interruption / recovery observation

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in self.published.sessionState = .interrupted }
            Task { await self.logger.log("Session interrupted: \(notification.userInfo ?? [:])", level: .warning) }
        }

        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.published.sessionState = .running }
            Task { await self.logger.log("Session interruption ended.", level: .info) }
        }

        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            Task { await self.logger.log("Runtime error: \(error?.localizedDescription ?? "unknown"). Beginning automatic recovery.", level: .error) }
            Task { @MainActor in self.published.sessionState = .recovering }
            self.triggerAutomaticRecovery()
        }
    }

    /// Automatic Recovery System: on a runtime error, ask the engine to
    /// find a working configuration again (excluding the one that just
    /// failed), without ever requiring the user to force-quit the app.
    private func triggerAutomaticRecovery() {
        guard let engine = compatibilityEngine else { return }
        let failedConfig = published.currentConfiguration
        Task {
            do {
                _ = try await engine.attemptRecovery(
                    mode: activeMode,
                    position: activePosition,
                    excluding: failedConfig,
                    using: self
                )
            } catch {
                await MainActor.run {
                    self.published.sessionState = .failed
                    self.published.lastError = error.localizedDescription
                }
            }
        }
    }
}
