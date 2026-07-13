//
//  FilterEngine.swift
//  CompatCam
//
//  Realtime, GPU-accelerated filters built on Core Image, rendered
//  through a Metal-backed CIContext for smooth live preview.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import UIKit

enum LiveFilter: String, CaseIterable, Identifiable {
    case natural   = "Natural"
    case film      = "Film"
    case vintage   = "Vintage"
    case warm      = "Warm"
    case cool      = "Cool"
    case noir      = "Noir"
    case dream     = "Dream"
    case soft      = "Soft"
    case classic   = "Classic"
    case vivid     = "Vivid"
    case cinematic = "Cinematic"
    case blackAndWhite = "Black & White"

    var id: String { rawValue }
}

final class FilterEngine {

    /// Metal-backed CIContext for hardware-accelerated rendering.
    let context: CIContext

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device)
        } else {
            context = CIContext(options: nil) // Simulator / unsupported hardware fallback
        }
    }

    /// Applies the given filter to an input image and returns the processed CIImage.
    /// All filters are chains of standard Core Image built-in filters — no
    /// external assets, no network, fully offline.
    func apply(_ filter: LiveFilter, to image: CIImage) -> CIImage {
        switch filter {
        case .natural:
            return image

        case .film:
            return image
                .applyingFilter("CIPhotoEffectTransfer")
                .applyingFilter("CIVignette", parameters: [kCIInputRadiusKey: 1.2, kCIInputIntensityKey: 0.35])

        case .vintage:
            let sepia = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.55])
            return sepia.applyingFilter("CIVignette", parameters: [kCIInputRadiusKey: 1.4, kCIInputIntensityKey: 0.5])

        case .warm:
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 4700, y: 15)
            ])

        case .cool:
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 8600, y: -10)
            ])

        case .noir:
            return image.applyingFilter("CIPhotoEffectNoir")

        case .dream:
            let blurred = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6])
            return image.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: blurred])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.15, kCIInputBrightnessKey: 0.05])

        case .soft:
            return image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5])
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.03, kCIInputContrastKey: 0.95])

        case .classic:
            return image.applyingFilter("CIPhotoEffectChrome")

        case .vivid:
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.45, kCIInputContrastKey: 1.08
            ])

        case .cinematic:
            return image
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.12, kCIInputSaturationKey: 0.92])
                .applyingFilter("CIVignette", parameters: [kCIInputRadiusKey: 1.6, kCIInputIntensityKey: 0.4])

        case .blackAndWhite:
            return image.applyingFilter("CIPhotoEffectMono")
        }
    }

    /// Renders a CIImage to a CGImage using the Metal-backed context, suitable
    /// for display or final photo compositing.
    func render(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent)
    }
}
