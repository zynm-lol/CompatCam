//
//  CameraDiagnosticsService.swift
//  CompatCam
//
//  Gathers a snapshot of every discoverable capture device and its
//  supported formats, using only public AVFoundation discovery APIs.
//  No private APIs, no Instagram code, no reverse engineering involved.
//

import AVFoundation
import Foundation

struct CameraDiagnosticsService {

    /// All device types we are allowed to probe with `AVCaptureDevice.DiscoverySession`.
    /// This list intentionally mirrors what the CompatibilityEngine can select from.
    static let allKnownDeviceTypes: [AVCaptureDevice.DeviceType] = {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
            .builtInTrueDepthCamera
        ]
        return types
    }()

    func discoverAllDevices() -> [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.allKnownDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        return session.devices
    }

    func snapshot(for device: AVCaptureDevice) -> DeviceCapabilitySnapshot {
        let formats = device.formats.prefix(50).map { format -> FormatSnapshot in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges.map {
                String(format: "%.0f–%.0f fps", $0.minFrameRate, $0.maxFrameRate)
            }
            let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let pixelFormatString = fourCharCodeToString(pixelFormat)

            return FormatSnapshot(
                description: "\(dims.width)x\(dims.height)",
                maxWidth: dims.width,
                maxHeight: dims.height,
                frameRateRanges: ranges,
                isHighestPhotoQualitySupported: format.isHighestPhotoQualitySupported,
                isVideoHDRSupported: format.isVideoHDRSupported,
                supportedPixelFormats: [pixelFormatString]
            )
        }

        return DeviceCapabilitySnapshot(
            id: device.uniqueID,
            localizedName: device.localizedName,
            deviceType: device.deviceType,
            position: device.position,
            modelID: device.modelID,
            manufacturer: device.manufacturer,
            isConnected: device.isConnected,
            isSuspended: device.isSuspended,
            hasFlash: device.hasFlash,
            hasTorch: device.hasTorch,
            formats: Array(formats)
        )
    }

    func fullReport() -> [DeviceCapabilitySnapshot] {
        discoverAllDevices().map(snapshot(for:))
    }

    private func fourCharCodeToString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        let scalars = bytes.map { UnicodeScalar($0) }
        let str = String(String.UnicodeScalarView(scalars))
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
