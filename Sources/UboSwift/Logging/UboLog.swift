import Foundation
import os

/// Granularity of UboSwift's diagnostic logging. Set
/// `UboLog.level = .debug` while developing to see every state-bus
/// message, action proto build, and subscription event in `Console.app`
/// (or the Xcode debug console). Defaults to `.info`, which keeps
/// production builds quiet without losing one-time lifecycle events
/// like connection success/failure.
public enum UboLogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case notice = 2
    case error = 3
    case fault = 4
    /// Suppress all UboSwift logs.
    case off = 5

    public static func < (lhs: UboLogLevel, rhs: UboLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Top-level access point for UboSwift's loggers. Apps tweak the
/// global `level` (e.g. from a settings toggle) to flip verbose
/// tracing on or off without rebuilding.
///
/// Example:
/// ```swift
/// UboLog.level = .debug
/// UboLog.input.debug("Activating input form for \(description.id)")
/// ```
public enum UboLog {
    /// Per-process minimum log level. Messages below this level are
    /// dropped *before* string interpolation, so it's cheap to leave
    /// `debug(...)` calls in shipping code. Marked
    /// `nonisolated(unsafe)` because it's a write-rarely / read-often
    /// flag — atomic writes aren't worth a lock.
    public nonisolated(unsafe) static var level: UboLogLevel = .info

    public static let connection = UboLogger(category: "connection")
    public static let subscription = UboLogger(category: "subscription")
    public static let input = UboLogger(category: "input")
    public static let action = UboLogger(category: "action")
    public static let audio = UboLogger(category: "audio")
    public static let camera = UboLogger(category: "camera")
    public static let discovery = UboLogger(category: "discovery")

    /// Subsystem string used by every UboSwift logger. Filter for it
    /// in Console.app to isolate UboSwift output.
    public static let subsystem = "com.ubopod.uboswift"
}

/// Thin wrapper around `os.Logger` that respects `UboLog.level` and
/// avoids string interpolation when a level is filtered out.
public struct UboLogger: Sendable {
    private let logger: Logger
    private let category: String

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: UboLog.subsystem, category: category)
    }

    public func debug(_ message: @autoclosure () -> String) {
        guard UboLog.level <= .debug else { return }
        let resolved = message()
        logger.debug("\(resolved, privacy: .public)")
    }

    public func info(_ message: @autoclosure () -> String) {
        guard UboLog.level <= .info else { return }
        let resolved = message()
        logger.info("\(resolved, privacy: .public)")
    }

    public func notice(_ message: @autoclosure () -> String) {
        guard UboLog.level <= .notice else { return }
        let resolved = message()
        logger.notice("\(resolved, privacy: .public)")
    }

    public func error(_ message: @autoclosure () -> String) {
        guard UboLog.level <= .error else { return }
        let resolved = message()
        logger.error("\(resolved, privacy: .public)")
    }

    public func fault(_ message: @autoclosure () -> String) {
        guard UboLog.level <= .fault else { return }
        let resolved = message()
        logger.fault("\(resolved, privacy: .public)")
    }
}
