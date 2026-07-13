//
//  CameraCompatibilityEngine.swift
//  CompatCam
//
//  THE HEART OF THE APPLICATION.
//
//  This engine never assumes a single camera configuration will work.
//  Given a CompatibilityMode, it builds an ordered queue of
//  CameraConfiguration candidates and asks the CameraManager to try each
//  one, in order, until one produces a running, stable AVCaptureSession.
//
//  Every attempt (success or failure) is written to DiagnosticsLogger so
//  the Diagnostics screen shows exactly what was tried and why it failed.
//
//  Only public AVFoundation APIs are used to discover devices and formats.
//

import AVFoundation
import Foundation

/// Errors the engine can surface. All are recoverable from the engine's
/// point of view — it will simply move on to the next candidate.
enum CompatibilityEngineError: LocalizedError {
    case noDevicesDiscovered
    case allConfigurationsFailed(attempts: Int)
    case sessionConfigurationRejected(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noDevicesDiscovered:
            return "No capture devices were discovered on this hardware."
        case .allConfigurationsFailed(let attempts):
            return "All \(attempts) compatibility configurations failed to produce a running session."
        case .sessionConfigurationRejected(let underlying):
            return "The capture session rejected this configuration: \(underlying.localizedDescription)"
        }
    }
}

/// Result of a single attempt, used for diagnostics + UI feedback.
struct EngineAttemptResult {
    let configuration: CameraConfiguration
    let succeeded: Bool
    let error: Error?
    let durationSeconds: Double
}

@MainActor
final class CameraCompatibilityEngine: ObservableObject {

    @Published private(set) var isSearching: Bool = false
    @Published private(set) var attempts: [EngineAttemptResult] = []
    @Published private(set) var activeConfiguration: CameraConfiguration?
    @Published private(set) var lastFailureSummary: String?

    private let logger = DiagnosticsLogger.shared

    /// Builds the ordered candidate list for a given mode and camera position.
    /// This is pure data generation — no side effects, no device access —
    /// which keeps it easy to unit test.
    func buildCandidates(for mode: CompatibilityMode, position: AVCaptureDevice.Position) -> [CameraConfiguration] {
        var candidates: [CameraConfiguration] = []

        for profile in mode.profileOrder {
            candidates.append(contentsOf: configurations(for: profile, position: position))
        }

        return candidates
    }

    /// Concrete configuration(s) generated for one named profile.
    /// Some profiles expand to more than one candidate (e.g. trying wide
    /// then dual-wide device types) to maximize the odds of success.
    private func configurations(for profile: CompatibilityProfile, position: AVCaptureDevice.Position) -> [CameraConfiguration] {
        switch profile {
        case .a_highestQuality:
            return [
                CameraConfiguration(
                    label: "Highest Quality – Triple/Dual Wide",
                    profile: profile,
                    deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
                    position: position,
                    sessionPreset: .photo,
                    preferredFormatSelector: .highestResolution,
                    stabilizationMode: .cinematicExtended,
                    autofocusMode: .continuousAutoFocus,
                    exposureMode: .continuousAutoExposure,
                    whiteBalanceMode: .continuousAutoWhiteBalance,
                    wantsHDR: true,
                    wantsHighResolutionCapture: true,
                    photoCodec: .hevc
                )
            ]

        case .b_balanced:
            return [
                CameraConfiguration(
                    label: "Balanced – Wide Angle",
                    profile: profile,
                    deviceTypes: [.builtInWideAngleCamera],
                    position: position,
                    sessionPreset: .photo,
                    preferredFormatSelector: .deviceDefault,
                    stabilizationMode: .auto,
                    autofocusMode: .continuousAutoFocus,
                    exposureMode: .continuousAutoExposure,
                    whiteBalanceMode: .continuousAutoWhiteBalance,
                    wantsHDR: true,
                    wantsHighResolutionCapture: true,
                    photoCodec: .jpeg
                )
            ]

        case .c_maxCompatibility:
            return [
                CameraConfiguration(
                    label: "Max Compatibility – Wide, .high preset",
                    profile: profile,
                    deviceTypes: [.builtInWideAngleCamera],
                    position: position,
                    sessionPreset: .high,
                    preferredFormatSelector: .deviceDefault,
                    stabilizationMode: .standard,
                    autofocusMode: .continuousAutoFocus,
                    exposureMode: .continuousAutoExposure,
                    whiteBalanceMode: .continuousAutoWhiteBalance,
                    wantsHDR: false,
                    wantsHighResolutionCapture: false,
                    photoCodec: .jpeg
                )
            ]

        case .d_legacy:
            return [
                CameraConfiguration(
                    label: "Legacy – Wide, .medium preset, no stabilization",
                    profile: profile,
                    deviceTypes: [.builtInWideAngleCamera],
                    position: position,
                    sessionPreset: .medium,
                    preferredFormatSelector: .deviceDefault,
                    stabilizationMode: .off,
                    autofocusMode: .autoFocus,
                    exposureMode: .continuousAutoExposure,
                    whiteBalanceMode: .continuousAutoWhiteBalance,
                    wantsHDR: false,
                    wantsHighResolutionCapture: false,
                    photoCodec: .jpeg
                )
            ]

        case .e_minimal:
            return [
                CameraConfiguration(
                    label: "Minimal – Wide, VGA preset",
                    profile: profile,
                    deviceTypes: [.builtInWideAngleCamera],
                    position: position,
                    sessionPreset: .vga640x480,
                    preferredFormatSelector: .lowestResolution,
                    stabilizationMode: .off,
                    autofocusMode: .autoFocus,
                    exposureMode: .autoExpose,
                    whiteBalanceMode: .autoWhiteBalance,
                    wantsHDR: false,
                    wantsHighResolutionCapture: false,
                    photoCodec: .jpeg
                )
            ]

        case .f_experimental:
            // Continuity Camera and External device types were removed here:
            // those exist for Mac/iPad accessory-camera scenarios and are
            // never returned for an iPhone's own built-in rear/front camera,
            // so trying them only burned an attempt slot for no benefit.
            // Instead this profile tries the most conservative possible
            // input-priority session with locked (non-continuous) modes,
            // which occasionally succeeds when continuous auto-adjustment
            // is what's tripping up a marginal sensor.
            return [
                CameraConfiguration(
                    label: "Experimental – Input Priority, Locked Modes",
                    profile: profile,
                    deviceTypes: [.builtInWideAngleCamera],
                    position: position,
                    sessionPreset: .inputPriority,
                    preferredFormatSelector: .mustSupportFrameRate(30),
                    stabilizationMode: .off,
                    autofocusMode: .locked,
                    exposureMode: .locked,
                    whiteBalanceMode: .locked,
                    wantsHDR: false,
                    wantsHighResolutionCapture: false,
                    photoCodec: .jpeg
                ),
                CameraConfiguration(
                    label: "Experimental – Unspecified Position Discovery",
                    profile: profile,
                    deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera],
                    position: .unspecified,
                    sessionPreset: .high,
                    preferredFormatSelector: .lowestResolution,
                    stabilizationMode: .off,
                    autofocusMode: .autoFocus,
                    exposureMode: .autoExpose,
                    whiteBalanceMode: .autoWhiteBalance,
                    wantsHDR: false,
                    wantsHighResolutionCapture: false,
                    photoCodec: .jpeg
                )
            ]
        }
    }

    /// Drives the CameraManager through each candidate until one succeeds.
    /// Returns the successful configuration, or throws if every candidate failed.
    @discardableResult
    func findWorkingConfiguration(
        mode: CompatibilityMode,
        position: AVCaptureDevice.Position,
        using manager: CameraManager
    ) async throws -> CameraConfiguration {

        isSearching = true
        attempts = []
        lastFailureSummary = nil
        defer { isSearching = false }

        let candidates = buildCandidates(for: mode, position: position)
        guard !candidates.isEmpty else {
            await logger.log("No candidates generated for mode \(mode.rawValue).", level: .error)
            throw CompatibilityEngineError.noDevicesDiscovered
        }

        await logger.log("Starting compatibility search: \(candidates.count) candidate(s) for mode '\(mode.rawValue)'.", level: .info)

        for candidate in candidates {
            let start = Date()
            await logger.log("Attempting configuration: \(candidate.description)", level: .info)

            do {
                try await manager.applyConfiguration(candidate)
                let duration = Date().timeIntervalSince(start)

                attempts.append(EngineAttemptResult(configuration: candidate, succeeded: true, error: nil, durationSeconds: duration))
                activeConfiguration = candidate

                await logger.log("SUCCESS: '\(candidate.label)' produced a running session in \(String(format: "%.2f", duration))s.", level: .success)
                return candidate

            } catch {
                let duration = Date().timeIntervalSince(start)
                attempts.append(EngineAttemptResult(configuration: candidate, succeeded: false, error: error, durationSeconds: duration))

                await logger.log("FAILED: '\(candidate.label)' — \(error.localizedDescription)", level: .warning)
                continue
            }
        }

        lastFailureSummary = "Tried \(candidates.count) configuration(s); none produced a running session."
        await logger.log(lastFailureSummary!, level: .error)
        throw CompatibilityEngineError.allConfigurationsFailed(attempts: candidates.count)
    }

    /// Called by the CameraManager's automatic recovery system when a
    /// previously-working session stops delivering frames or is interrupted
    /// in a way that doesn't resolve on its own.
    func attemptRecovery(
        mode: CompatibilityMode,
        position: AVCaptureDevice.Position,
        excluding failedConfiguration: CameraConfiguration?,
        using manager: CameraManager
    ) async throws -> CameraConfiguration {

        await logger.log("Automatic recovery triggered.", level: .warning)

        var candidates = buildCandidates(for: mode, position: position)
        if let failed = failedConfiguration {
            candidates.removeAll { $0.profile == failed.profile && $0.label == failed.label }
        }

        guard !candidates.isEmpty else {
            // Fall back to the full "maximum compatibility" ladder as a last resort.
            candidates = buildCandidates(for: .maximumCompatibility, position: position)
        }

        for candidate in candidates {
            do {
                try await manager.applyConfiguration(candidate)
                activeConfiguration = candidate
                await logger.log("Recovery succeeded with '\(candidate.label)'.", level: .success)
                return candidate
            } catch {
                await logger.log("Recovery attempt '\(candidate.label)' failed: \(error.localizedDescription)", level: .warning)
                continue
            }
        }

        await logger.log("Automatic recovery exhausted all candidates.", level: .error)
        throw CompatibilityEngineError.allConfigurationsFailed(attempts: candidates.count)
    }
}
