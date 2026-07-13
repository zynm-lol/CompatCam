//
//  ManualControlsView.swift
//  CompatCam
//
//  Advanced manual controls: lets the user hand-pick device, session
//  preset, format-selection strategy, stabilization, focus/exposure/WB
//  modes, HDR, and codec, then applies them live without restarting.
//

import AVFoundation
import SwiftUI

struct ManualControlsView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    @State private var position: AVCaptureDevice.Position = .back
    @State private var preset: AVCaptureSession.Preset = .photo
    @State private var formatSelector: FormatSelector = .deviceDefault
    @State private var stabilization: AVCaptureVideoStabilizationMode = .auto
    @State private var focusMode: AVCaptureDevice.FocusMode = .continuousAutoFocus
    @State private var exposureMode: AVCaptureDevice.ExposureMode = .continuousAutoExposure
    @State private var whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode = .continuousAutoWhiteBalance
    @State private var wantsHDR = true
    @State private var wantsHighRes = true
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    Picker("Position", selection: $position) {
                        Text("Back").tag(AVCaptureDevice.Position.back)
                        Text("Front").tag(AVCaptureDevice.Position.front)
                    }
                    Picker("Lens", selection: $deviceTypes) {
                        Text("Wide Angle").tag([AVCaptureDevice.DeviceType.builtInWideAngleCamera])
                        Text("Ultra Wide").tag([AVCaptureDevice.DeviceType.builtInUltraWideCamera])
                        Text("Telephoto").tag([AVCaptureDevice.DeviceType.builtInTelephotoCamera])
                        Text("Dual Wide").tag([AVCaptureDevice.DeviceType.builtInDualWideCamera])
                        Text("Triple").tag([AVCaptureDevice.DeviceType.builtInTripleCamera])
                    }
                }

                Section("Session") {
                    Picker("Preset", selection: $preset) {
                        Text("Photo").tag(AVCaptureSession.Preset.photo)
                        Text("High").tag(AVCaptureSession.Preset.high)
                        Text("Medium").tag(AVCaptureSession.Preset.medium)
                        Text("VGA (Safe Mode)").tag(AVCaptureSession.Preset.vga640x480)
                        Text("Input Priority").tag(AVCaptureSession.Preset.inputPriority)
                    }
                    Picker("Format Strategy", selection: $formatSelector) {
                        Text("Device Default").tag(FormatSelector.deviceDefault)
                        Text("Highest Resolution").tag(FormatSelector.highestResolution)
                        Text("Lowest Resolution").tag(FormatSelector.lowestResolution)
                        Text("Must Support 30fps").tag(FormatSelector.mustSupportFrameRate(30))
                    }
                }

                Section("Stabilization & Focus") {
                    Picker("Stabilization", selection: $stabilization) {
                        Text("Off").tag(AVCaptureVideoStabilizationMode.off)
                        Text("Standard").tag(AVCaptureVideoStabilizationMode.standard)
                        Text("Cinematic").tag(AVCaptureVideoStabilizationMode.cinematicExtended)
                        Text("Auto").tag(AVCaptureVideoStabilizationMode.auto)
                    }
                    Picker("Focus Mode", selection: $focusMode) {
                        Text("Locked").tag(AVCaptureDevice.FocusMode.locked)
                        Text("Auto").tag(AVCaptureDevice.FocusMode.autoFocus)
                        Text("Continuous").tag(AVCaptureDevice.FocusMode.continuousAutoFocus)
                    }
                }

                Section("Exposure & White Balance") {
                    Picker("Exposure", selection: $exposureMode) {
                        Text("Locked").tag(AVCaptureDevice.ExposureMode.locked)
                        Text("Auto").tag(AVCaptureDevice.ExposureMode.autoExpose)
                        Text("Continuous").tag(AVCaptureDevice.ExposureMode.continuousAutoExposure)
                    }
                    Picker("White Balance", selection: $whiteBalanceMode) {
                        Text("Locked").tag(AVCaptureDevice.WhiteBalanceMode.locked)
                        Text("Auto").tag(AVCaptureDevice.WhiteBalanceMode.autoWhiteBalance)
                        Text("Continuous").tag(AVCaptureDevice.WhiteBalanceMode.continuousAutoWhiteBalance)
                    }
                }

                Section("Photo Quality") {
                    Toggle("HDR", isOn: $wantsHDR)
                    Toggle("High Resolution Capture", isOn: $wantsHighRes)
                    Toggle("RAW Capture", isOn: $viewModel.isRawCaptureEnabled)
                        .disabled(!viewModel.manager.published.isRawCaptureAvailable)
                    if !viewModel.manager.published.isRawCaptureAvailable {
                        Text("RAW isn't supported by the active device/format.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Stepper("Burst count: \(viewModel.burstCount)", value: $viewModel.burstCount, in: 2...20)
                    Text("Long-press the shutter button to capture a burst.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Manual Exposure (ISO / Shutter)") {
                    Toggle("Use Custom Exposure", isOn: $viewModel.useCustomExposure)
                        .disabled(!viewModel.manager.published.supportsCustomExposure)
                        .onChange(of: viewModel.useCustomExposure) { _, _ in viewModel.applyCustomExposure() }

                    if !viewModel.manager.published.supportsCustomExposure {
                        Text("This device doesn't support manual exposure.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if viewModel.useCustomExposure {
                        let isoRange = viewModel.manager.published.currentISORange
                        VStack(alignment: .leading) {
                            Text("ISO: \(Int(viewModel.manualISO))")
                            Slider(
                                value: $viewModel.manualISO,
                                in: isoRange,
                                onEditingChanged: { editing in if !editing { viewModel.applyCustomExposure() } }
                            )
                        }
                        VStack(alignment: .leading) {
                            Text("Shutter: 1/\(Int(1 / max(viewModel.manualShutterSeconds, 0.0001)))s")
                            Slider(
                                value: $viewModel.manualShutterSeconds,
                                in: 0.0005...(1.0/3.0),
                                onEditingChanged: { editing in if !editing { viewModel.applyCustomExposure() } }
                            )
                        }
                    }
                }

                Section {
                    Button {
                        Task { await applyNow() }
                    } label: {
                        if isApplying {
                            ProgressView()
                        } else {
                            Text("Apply Configuration")
                        }
                    }
                    .disabled(isApplying)
                }
            }
            .navigationTitle("Manual Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func applyNow() async {
        isApplying = true
        defer { isApplying = false }

        let configuration = CameraConfiguration(
            label: "Manual Configuration",
            profile: .b_balanced,
            deviceTypes: deviceTypes,
            position: position,
            sessionPreset: preset,
            preferredFormatSelector: formatSelector,
            stabilizationMode: stabilization,
            autofocusMode: focusMode,
            exposureMode: exposureMode,
            whiteBalanceMode: whiteBalanceMode,
            wantsHDR: wantsHDR,
            wantsHighResolutionCapture: wantsHighRes,
            photoCodec: .hevc
        )

        await viewModel.applyManualConfiguration(configuration)
        if viewModel.startupErrorMessage == nil {
            dismiss()
        }
    }
}
