import Foundation
import os
import Observation

/// Severity ordering for log entries. `Comparable` so the Debug Log filter can
/// say "show >= warning". Order is: debug < info < warning < error.
enum LogLevel: String, Comparable, Sendable {
    case debug, info, warning, error

    private var weight: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.weight < rhs.weight }
}

/// One log entry. `Identifiable` so SwiftUI's `ForEach` in DebugLogView can
/// stably track rows; `Sendable` so we can construct one on a background
/// thread and ferry it to MainActor.
struct LogEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String
}

/// In-memory ring buffer for log entries (capped at 5000). Lives on MainActor so
/// the Debug Log view can read it without thread-safety ceremony. `@Observable`
/// so the view auto-refreshes as entries arrive.
///
/// The cap matters: without it a long-running session would balloon memory.
/// 5000 is enough to keep ~20 minutes of typical activity.
@MainActor
@Observable
final class LogStore {
    static let shared = LogStore()

    private(set) var entries: [LogEntry] = []
    private let cap = 5_000

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
    }

    func clear() { entries.removeAll() }
}

/// Centralized list of category strings used in `Log.<level>(_:category:)` calls.
/// Used both at the call sites and by `DebugLogView` to populate its filter
/// toggles. Adding a new category here automatically makes it filterable in the UI.
///
/// `nonisolated` on each constant so non-MainActor code (actors, background tasks)
/// can reference them — under our project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor`, untouched constants would inherit MainActor isolation.
enum LogCategory {
    nonisolated static let ui = "ui"
    nonisolated static let library = "library"
    nonisolated static let doppler = "doppler"
    nonisolated static let llm = "llm"
    nonisolated static let playlist = "playlist"
    nonisolated static let process = "process"

    nonisolated static let all: [String] = [ui, library, doppler, llm, playlist, process]
}

/// The logging facade — call from anywhere (main thread or background, any
/// isolation context). Two destinations:
/// 1. **OSLog** (Console.app, sysdiagnose) via the `os.Logger` instance below.
///    Marked `.public` privacy so messages aren't redacted in Console.
/// 2. **In-app `LogStore`** (rendered by DebugLogView). Hopped to MainActor via
///    `Task { @MainActor in ... }` since LogStore is MainActor-isolated.
///
/// `@autoclosure` on the message argument means the string is only constructed
/// when the call actually fires (no allocation overhead for `Log.debug` calls
/// in release builds where they might be filtered).
enum Log {
    nonisolated private static let osLog = Logger(
        subsystem: "studio.rischio.mixtape",
        category: "app"
    )

    nonisolated static func debug(_ message: @autoclosure () -> String, category: String = LogCategory.ui) {
        record(.debug, category, message())
    }

    nonisolated static func info(_ message: @autoclosure () -> String, category: String = LogCategory.ui) {
        record(.info, category, message())
    }

    nonisolated static func warning(_ message: @autoclosure () -> String, category: String = LogCategory.ui) {
        record(.warning, category, message())
    }

    nonisolated static func error(_ message: @autoclosure () -> String, category: String = LogCategory.ui) {
        record(.error, category, message())
    }

    /// Internal fan-out: writes to OSLog synchronously and queues an append to
    /// LogStore on MainActor. The MainActor hop means a burst of logs from a
    /// background sync may arrive in a slightly different order than they were
    /// emitted from — accept that vs blocking the caller.
    nonisolated private static func record(_ level: LogLevel, _ category: String, _ msg: String) {
        let prefixed = "[\(category)] \(msg)"
        switch level {
        case .debug:   osLog.debug("\(prefixed, privacy: .public)")
        case .info:    osLog.info("\(prefixed, privacy: .public)")
        case .warning: osLog.warning("\(prefixed, privacy: .public)")
        case .error:   osLog.error("\(prefixed, privacy: .public)")
        }
        let entry = LogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            category: category,
            message: msg
        )
        Task { @MainActor in
            LogStore.shared.append(entry)
        }
    }
}
