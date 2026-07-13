//
//  CameraConfiguration.swift
//  CompatCam
//
//  Core value types describing a single candidate camera configuration
//  that the CompatibilityEngine can attempt to initialize, plus the
//  named "profiles" the engine walks through automatically.
//

import AVFoundation
import Foundation

/// A single, fully-specified attempt at configuring the capture session.
/// The CompatibilityEngine generates a queue of these and tries them in order.
struct CameraConfiguration: Identifiable, Equatable, CustomStringConvertible {

    let id = UUID()

    /// Human readable name used in logs / diagnostics UI.
    let label: String

    /// Which profile this configuration belongs to (for grouping in diagnostics).
    let profile: CompatibilityProfile

    let deviceTypes: [AVCaptureDevice.DeviceType]
    let position: AVCaptureDevice.Position
    let sessionPreset: AVCaptureSession.Preset

    /// If nil, the engine lets the device pick its default active format.
    let preferredFormatSelector: FormatSelector

    let stabilizationMode: AVCaptureVideoStabilizationMode
    let autofocusMode: AVCaptureDevice.FocusMode
    let exposureMode: AVCaptureDevice.ExposureMode
    let whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode

    let wantsHDR: Bool
    let wantsHighResolutionCapture: Bool
    let photoCodec: AVVideoCodecType?

    var description: String {
        "\(label) [\(profile.rawValue)] preset=\(sessionPreset.rawValue) pos=\(position.rawValue)"
    }

    static func == (lhs: CameraConfiguration, rhs: CameraConfiguration) -> Bool {
        lhs.id == rhs.id
    }
}

/// Strategy used to pick an `AVCaptureDevice.Format` once a device is opened.
/// Kept as an enum (rather than a closure) so configurations stay `Equatable`
/// and safely `Sendable` across actor boundaries.
enum FormatSelector: Equatable {
    case deviceDefault
    case highestResolution
    case lowestResolution
    case closestTo(width: Int32, height: Int32)
    case mustSupportFrameRate(Double)
}

/// The named compatibility profiles. The engine walks these in order
/// (A -> F) by default; "Compatibility Mode" and friends in the UI simply
/// change the starting point / subset of this list.
enum CompatibilityProfile: String, CaseIterable, Identifiable {
    case a_highestQuality   = "Profile A – Highest Quality"
    case b_balanced         = "Profile B – Balanced"
    case c_maxCompatibility = "Profile C – Maximum Compatibility"
    case d_legacy           = "Profile D – Legacy Configuration"
    case e_minimal          = "Profile E – Minimal Configuration"
    case f_experimental     = "Profile F – Experimental"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .a_highestQuality:
            return "Best available format, full multi-cam discovery, HDR, stabilization on."
        case .b_balanced:
            return "photo preset, standard discovery set, cinematic stabilization."
        case .c_maxCompatibility:
            return "Conservative preset, single wide-angle device, auto everything."
        case .d_legacy:
            return "builtInWideAngleCamera only, .high preset, no HDR, no stabilization."
        case .e_minimal:
            return ".vga640x480 preset, minimal feature set, maximum chance of success."
        case .f_experimental:
            return "Tries external / continuity / unusual device types as a last resort."
        }
    }
}

/// User-selectable compatibility modes shown in the "Camera Compatibility" menu.
/// Each maps to a subset / ordering of `CompatibilityProfile`.
enum CompatibilityMode: String, CaseIterable, Identifiable {
    case standard             = "Standard Mode"
    case compatibility        = "Compatibility Mode"
    case maximumCompatibility = "Maximum Compatibility"
    case experimental         = "Experimental Mode"
    case lowResolutionSafe    = "Low Resolution Safe Mode"
    case manual               = "Manual Configuration"

    // NOTE: a separate "Debug Mode" was intentionally removed. It only ever
    // duplicated Maximum Compatibility's full A–F ladder, and its one
    // distinguishing feature — seeing every device on both positions — is
    // already covered by the Diagnostics screen, which enumerates all
    // devices regardless of the active mode. Keeping both was redundant.

    var id: String { rawValue }

    /// The ordered list of profiles the engine should try for this mode.
    var profileOrder: [CompatibilityProfile] {
        switch self {
        case .standard:
            return [.a_highestQuality, .b_balanced]
        case .compatibility:
            return [.b_balanced, .c_maxCompatibility, .d_legacy]
        case .maximumCompatibility:
            return CompatibilityProfile.allCases // A through F, full ladder
        case .experimental:
            return [.f_experimental, .c_maxCompatibility, .e_minimal]
        case .lowResolutionSafe:
            return [.e_minimal, .d_legacy]
        case .manual:
            return [] // user builds their own CameraConfiguration
        }
    }
}
