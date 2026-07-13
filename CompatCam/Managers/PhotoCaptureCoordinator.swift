//
//  PhotoCaptureCoordinator.swift
//  CompatCam
//
//  Bridges AVCapturePhotoCaptureDelegate's callback-based API into
//  Swift Concurrency, and saves the result to the Photos library.
//

import AVFoundation
import Photos
import UIKit

enum PhotoCaptureError: LocalizedError {
    case captureFailed(underlying: Error)
    case noImageData
    case photosPermissionDenied
    case saveFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .captureFailed(let e): return "Capture failed: \(e.localizedDescription)"
        case .noImageData: return "The capture produced no image data."
        case .photosPermissionDenied: return "Photos library access was denied."
        case .saveFailed(let e): return "Could not save photo: \(e.localizedDescription)"
        }
    }
}

final class PhotoCaptureCoordinator: NSObject, AVCapturePhotoCaptureDelegate {

    /// A single capture can deliver more than one representation (e.g. a
    /// RAW file alongside a processed JPEG/HEIF preview). Both are
    /// collected here and returned together.
    struct CaptureResult {
        var processedData: Data?
        var rawData: Data?
    }

    private var continuation: CheckedContinuation<CaptureResult, Error>?
    private var pendingResult = CaptureResult()
    private let logger = DiagnosticsLogger.shared

    /// Builds settings for a standard (non-RAW) capture using the requested codec.
    static func standardSettings(codec: AVVideoCodecType, flashMode: AVCaptureDevice.FlashMode, highResolution: Bool) -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
        settings.flashMode = flashMode
        settings.isHighResolutionPhotoEnabled = highResolution
        return settings
    }

    /// Builds settings for a RAW + processed-preview capture, if the output
    /// actually supports RAW on the current device/format. Falls back to
    /// `nil` (caller should use `standardSettings` instead) if not supported.
    static func rawSettings(output: AVCapturePhotoOutput, flashMode: AVCaptureDevice.FlashMode) -> AVCapturePhotoSettings? {
        guard let rawFormat = output.availableRawPhotoPixelFormatTypes.first else { return nil }
        let processedFormat = output.availablePhotoCodecTypes.contains(.hevc) ? AVVideoCodecType.hevc : .jpeg
        let settings = AVCapturePhotoSettings(
            rawPixelFormatType: rawFormat,
            processedFormat: [AVVideoCodecKey: processedFormat]
        )
        settings.flashMode = flashMode
        return settings
    }

    /// Captures a single photo using the given settings and returns
    /// whatever representations (processed and/or RAW) were produced.
    func capturePhoto(with output: AVCapturePhotoOutput, settings: AVCapturePhotoSettings) async throws -> CaptureResult {
        pendingResult = CaptureResult()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            continuation?.resume(throwing: PhotoCaptureError.captureFailed(underlying: error))
            continuation = nil
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            continuation?.resume(throwing: PhotoCaptureError.noImageData)
            continuation = nil
            return
        }

        // RAW settings deliver two callbacks: one with isRawPhoto == true,
        // one with the processed preview. We accumulate both, then resolve
        // once we've seen the processed one (which always arrives last).
        if photo.isRawPhoto {
            pendingResult.rawData = data
        } else {
            pendingResult.processedData = data
            continuation?.resume(returning: pendingResult)
            continuation = nil
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        // If only a RAW representation was requested and produced (no
        // separate processed callback will follow), resolve here.
        if let continuation, resolvedSettings.rawPhotoDimensions.width > 0, pendingResult.processedData == nil, pendingResult.rawData != nil {
            continuation.resume(returning: pendingResult)
            self.continuation = nil
        }
    }

    /// Saves JPEG/HEIF (and optionally a sibling RAW/DNG) file data to Photos.
    static func save(_ result: CaptureResult) async throws {
        let granted = await PHPhotoLibraryAuthorizationHelper.requestAddOnly()
        guard granted else { throw PhotoCaptureError.photosPermissionDenied }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                if let processed = result.processedData {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: processed, options: nil)
                    if let raw = result.rawData {
                        let rawOptions = PHAssetResourceCreationOptions()
                        rawOptions.shouldMoveFile = false
                        request.addResource(with: .alternatePhoto, data: raw, options: rawOptions)
                    }
                } else if let raw = result.rawData {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: raw, options: nil)
                }
            }, completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoCaptureError.saveFailed(underlying: error ?? NSError(domain: "CompatCam", code: -1)))
                }
            })
        }
    }
}
