//
//  DiagnosticsModels.swift
//  CompatCam
//

import AVFoundation
import Foundation

/// A single timestamped diagnostic log line. Kept lightweight so the
/// diagnostics screen can render thousands of entries without stutter.
struct DiagnosticLogEntry: Identifiable, Equatable {
    enum Level: String {
        case info, warning, error, success
    }

    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String

    static func == (lhs: DiagnosticLogEntry, rhs: DiagnosticLogEntry) -> Bool {
        lhs.id == rhs.id
    }
}

/// A snapshot of everything the diagnostics screen wants to show about
/// one physical capture device, gathered purely from public AVFoundation APIs.
struct DeviceCapabilitySnapshot: Identifiable {
    let id: String // AVCaptureDevice.uniqueID
    let localizedName: String
    let deviceType: AVCaptureDevice.DeviceType
    let position: AVCaptureDevice.Position
    let modelID: String
    let manufacturer: String
    let isConnected: Bool
    let isSuspended: Bool
    let hasFlash: Bool
    let hasTorch: Bool
    let supportsHDR: Bool = true // resolved per-format at query time; see CameraDiagnosticsService
    let formats: [FormatSnapshot]
}

struct FormatSnapshot: Identifiable {
    let id = UUID()
    let description: String
    let maxWidth: Int32
    let maxHeight: Int32
    let frameRateRanges: [String]
    let isHighestPhotoQualitySupported: Bool
    let isVideoHDRSupported: Bool
    let supportedPixelFormats: [String]
}

/// Live session-level state, surfaced to both diagnostics and the main capture UI.
enum SessionState: String {
    case notStarted        = "Not Started"
    case discoveringDevice = "Discovering Devices"
    case configuring       = "Configuring"
    case running           = "Running"
    case interrupted       = "Interrupted"
    case recovering        = "Recovering"
    case failed            = "Failed"
}
