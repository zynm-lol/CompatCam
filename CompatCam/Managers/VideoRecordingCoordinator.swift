//
//  VideoRecordingCoordinator.swift
//  CompatCam
//
//  Bridges AVCaptureMovieFileOutput's delegate-based recording API into
//  Swift Concurrency, and drives a simple elapsed-time ticker for the UI.
//

import AVFoundation
import Photos
import Foundation

/// Tiny shared helper so both photo and video coordinators request Photos
/// permission the same way without duplicating the authorization dance.
enum PHPhotoLibraryAuthorizationHelper {
    static func requestAddOnly() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }
}

final class VideoRecordingCoordinator: NSObject, AVCaptureFileOutputRecordingDelegate {

    private var continuation: CheckedContinuation<URL, Error>?
    private var timer: Timer?
    private var startDate: Date?
    private var onTick: ((Int) -> Void)?

    func beginTracking(onTick: @escaping (Int) -> Void) {
        self.onTick = onTick
        startDate = Date()
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.startDate else { return }
            self.onTick?(Int(Date().timeIntervalSince(start)))
        }
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }

    func startRecording(output: AVCaptureMovieFileOutput, to url: URL) {
        output.startRecording(to: url, recordingDelegate: self)
    }

    func stopRecording(output: AVCaptureMovieFileOutput) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            output.stopRecording()
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        timer?.invalidate()
        timer = nil

        if let error {
            // AVFoundation sometimes reports a non-fatal "error" even on a
            // successful stop (e.g. maximum duration reached); the file is
            // still usable in that case, so check whether it was written.
            let nsError = error as NSError
            let successfulEvenThoughError = (nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true
            if !successfulEvenThoughError {
                continuation?.resume(throwing: error)
                continuation = nil
                return
            }
        }

        continuation?.resume(returning: outputFileURL)
        continuation = nil
    }

    /// Saves a recorded movie file to the Photos library.
    static func saveToPhotos(_ url: URL) async throws {
        let granted = await PHPhotoLibraryAuthorizationHelper.requestAddOnly()
        guard granted else { throw PhotoCaptureError.photosPermissionDenied }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }, completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoCaptureError.saveFailed(underlying: error ?? NSError(domain: "CompatCam", code: -2)))
                }
            })
        }
    }
}
