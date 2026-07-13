//
//  FrameAnalysisCoordinator.swift
//  CompatCam
//
//  Consumes AVCaptureVideoDataOutput sample buffers to produce:
//   - a live RGB histogram (for the Histogram overlay)
//   - a focus-peaking overlay (edges of in-focus areas highlighted)
//   - a zebra-stripe overlay (highlights near-clipped highlights)
//
//  All three are computed with Core Image / Accelerate from the same
//  CVPixelBuffer AVFoundation already hands us — no extra capture path,
//  no private API. Work is throttled (every Nth frame) and dispatched off
//  the video-output queue's completion so it never blocks frame delivery.
//

import Accelerate
import AVFoundation
import CoreImage
import UIKit

@MainActor
final class FrameAnalysisCoordinator: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published var histogramBins: [Float] = Array(repeating: 0, count: 64)
    @Published var focusPeakingOverlay: CGImage?
    @Published var zebraOverlay: CGImage?

    var isHistogramEnabled = false
    var isFocusPeakingEnabled = false
    var isZebraEnabled = false

    /// Every Nth frame is analyzed; the rest are dropped immediately. Live
    /// preview keeps running at full rate via the separate preview layer —
    /// this only throttles the *analysis* path.
    private let frameStride = 6
    private var frameCounter = 0

    private let context: CIContext
    private let analysisQueue = DispatchQueue(label: "com.compatcam.frameAnalysis", qos: .utility)

    init(context: CIContext) {
        self.context = context
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        Task { @MainActor in
            self.frameCounter += 1
            guard self.frameCounter % self.frameStride == 0 else { return }
            guard self.isHistogramEnabled || self.isFocusPeakingEnabled || self.isZebraEnabled else { return }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

            if self.isHistogramEnabled {
                self.updateHistogram(from: ciImage)
            }
            if self.isFocusPeakingEnabled {
                self.updateFocusPeaking(from: ciImage)
            }
            if self.isZebraEnabled {
                self.updateZebra(from: ciImage)
            }
        }
    }

    // MARK: - Histogram

    private func updateHistogram(from image: CIImage) {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let filter = CIFilter(name: "CIAreaHistogram", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: extent),
            "inputScale": 1.0,
            "inputCount": 64
        ])

        guard let outputImage = filter?.outputImage else { return }

        var bitmap = [Float](repeating: 0, count: 64 * 4)
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 64 * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: 64, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )

        // Average the RGB channels into a single luminance-ish histogram for display.
        var luminance = [Float](repeating: 0, count: 64)
        for i in 0..<64 {
            let r = bitmap[i * 4]
            let g = bitmap[i * 4 + 1]
            let b = bitmap[i * 4 + 2]
            luminance[i] = (r + g + b) / 3.0
        }
        let maxValue = luminance.max() ?? 1
        histogramBins = maxValue > 0 ? luminance.map { $0 / maxValue } : luminance
    }

    // MARK: - Focus peaking

    /// Highlights high-frequency (in-focus) edges in a bright color, using
    /// Core Image's built-in edge-detection convolution — a standard,
    /// well-understood technique, not anything camera-hardware-specific.
    private func updateFocusPeaking(from image: CIImage) {
        let edges = image
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6.0])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])

        focusPeakingOverlay = context.createCGImage(edges, from: image.extent)
    }

    // MARK: - Zebra (overexposure) stripes

    /// Marks pixels above a brightness threshold — the classic "zebra
    /// stripes" exposure aid — using a simple luminance threshold filter.
    private func updateZebra(from image: CIImage) {
        let mono = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let thresholded = applyThreshold(mono)
        zebraOverlay = context.createCGImage(thresholded, from: image.extent)
    }

    /// `CIColorThreshold` isn't available pre-iOS 17 in all configurations,
    /// so this provides a manual fallback using `CIColorMatrix` + `CIStepFunction`-like clamping.
    private func applyThreshold(_ image: CIImage) -> CIImage {
        if #available(iOS 17.0, *), CIFilter(name: "CIColorThreshold") != nil {
            return image.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.92])
        }
        // Fallback: steep contrast curve approximates a hard threshold.
        return image.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 12.0,
            kCIInputBrightnessKey: -0.85
        ])
    }
}
