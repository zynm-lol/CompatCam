//
//  DiagnosticsLogger.swift
//  CompatCam
//
//  A tiny actor-based logger. All camera-related subsystems funnel their
//  events through this so the Diagnostics screen has a single, ordered,
//  thread-safe source of truth without any locks in call sites.
//

import Foundation
import Combine

actor DiagnosticsLogger {

    static let shared = DiagnosticsLogger()

    private(set) var entries: [DiagnosticLogEntry] = []
    private let maxEntries = 2000

    /// Published mirror for SwiftUI. Updated on the main actor whenever a
    /// new entry is appended, so views can simply `@ObservedObject` this.
    @MainActor final class Publisher: ObservableObject {
        @Published var entries: [DiagnosticLogEntry] = []
    }

    let publisher = Publisher()

    private init() {}

    func log(_ message: String, level: DiagnosticLogEntry.Level = .info) {
        let entry = DiagnosticLogEntry(timestamp: Date(), level: level, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        let snapshot = entries
        Task { @MainActor in
            publisher.entries = snapshot
        }
    }

    func clear() {
        entries.removeAll()
        Task { @MainActor in
            publisher.entries = []
        }
    }

    func exportText() -> String {
        entries.map { entry in
            let df = ISO8601DateFormatter()
            return "[\(df.string(from: entry.timestamp))] [\(entry.level.rawValue.uppercased())] \(entry.message)"
        }.joined(separator: "\n")
    }
}
