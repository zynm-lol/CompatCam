//
//  CompatibilityMenuView.swift
//  CompatCam
//
//  The "Camera Compatibility" menu required by the spec, listing every
//  mode and letting the user switch without restarting the app.
//

import SwiftUI

struct CompatibilityMenuView: View {
    let currentMode: CompatibilityMode
    let onSelect: (CompatibilityMode) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(CompatibilityMode.allCases) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.rawValue)
                                .font(.headline)
                            Text(profileSummary(for: mode))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mode == currentMode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Camera Compatibility")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func profileSummary(for mode: CompatibilityMode) -> String {
        if mode.profileOrder.isEmpty {
            return "Build your own configuration in Manual Controls."
        }
        return mode.profileOrder.map(\.rawValue).joined(separator: " → ")
    }
}

#Preview {
    CompatibilityMenuView(currentMode: .standard, onSelect: { _ in })
}
