//
//  DiagnosticsView.swift
//  CompatCam
//
//  The Camera Diagnostics page: detected cameras, formats, session state,
//  attempt history, and raw logs — all derived from public API calls.
//

import AVFoundation
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var engine: CameraCompatibilityEngine
    let manager: CameraManager

    @ObservedObject private var logPublisher = DiagnosticsLogger.shared.publisher
    @State private var devices: [DeviceCapabilitySnapshot] = []
    @Environment(\.dismiss) private var dismiss

    private let diagnosticsService = CameraDiagnosticsService()

    var body: some View {
        NavigationStack {
            List {
                Section("Session") {
                    LabeledContent("State", value: manager.published.sessionState.rawValue)
                    LabeledContent("Active Configuration", value: manager.published.currentConfiguration?.label ?? "—")
                    LabeledContent("Active Device", value: manager.published.currentDevice?.localizedName ?? "—")
                    if let error = manager.published.lastError {
                        LabeledContent("Last Error", value: error).foregroundStyle(.red)
                    }
                }

                Section("Compatibility Attempts") {
                    if engine.attempts.isEmpty {
                        Text("No attempts recorded yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(engine.attempts.enumerated()), id: \.offset) { _, attempt in
                            HStack {
                                Image(systemName: attempt.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(attempt.succeeded ? .green : .red)
                                VStack(alignment: .leading) {
                                    Text(attempt.configuration.label).font(.subheadline)
                                    Text(String(format: "%.2fs", attempt.durationSeconds))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Detected Cameras") {
                    if devices.isEmpty {
                        Text("Scanning…").foregroundStyle(.secondary)
                    } else {
                        ForEach(devices) { device in
                            DisclosureGroup(device.localizedName) {
                                LabeledContent("Position", value: device.position == .back ? "Back" : device.position == .front ? "Front" : "Unspecified")
                                LabeledContent("Model ID", value: device.modelID)
                                LabeledContent("Manufacturer", value: device.manufacturer)
                                LabeledContent("Connected", value: device.isConnected ? "Yes" : "No")
                                LabeledContent("Suspended", value: device.isSuspended ? "Yes" : "No")
                                LabeledContent("Flash", value: device.hasFlash ? "Yes" : "No")
                                LabeledContent("Torch", value: device.hasTorch ? "Yes" : "No")
                                LabeledContent("Unique ID (local only)", value: device.id)
                                Text("Formats (\(device.formats.count) shown)").font(.caption.bold())
                                ForEach(device.formats.prefix(8)) { format in
                                    Text("\(format.description) · \(format.frameRateRanges.joined(separator: ", "))")
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                }

                Section("Logs") {
                    ForEach(logPublisher.entries.suffix(200).reversed()) { entry in
                        Text("[\(entry.level.rawValue.uppercased())] \(entry.message)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(color(for: entry.level))
                    }
                }
            }
            .navigationTitle("Camera Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear Logs") {
                        Task { await DiagnosticsLogger.shared.clear() }
                    }
                }
            }
            .task {
                devices = diagnosticsService.fullReport()
            }
        }
    }

    private func color(for level: DiagnosticLogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}
