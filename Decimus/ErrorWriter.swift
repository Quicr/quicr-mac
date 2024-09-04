import os
import OSLog

/// Application logger.
class DecimusLogger {
    private let logger: Logger
    private let category: String

    /// Possible log level.
    enum LogLevel: UInt8 {
        /// An error, always presented to the user.
        case error
        /// A warning, optionally presented to the user.
        case warning
        /// A informational message, optionally presented to the user.
        case info
        /// A debug message, optionally presented to the user.
        case debug
    }

    /// A log message and metadata.
    struct DecimusLogEntry: Identifiable {
        /// Unique identifier for this log message.
        let id = UUID()
        /// The date the associated event occurred.
        let date: Date
        /// The category this message belongs to.
        let category: String
        /// The level of the message.
        let level: LogLevel
        /// The actual log message.
        let message: String
    }

    /// SwiftUI holder for log messages.
    class ObservableLogs: ObservableObject {
        @Published var alerts: [DecimusLogEntry] = []
    }

    /// Shared app-wide log holder.
    static let shared = ObservableLogs()

    /// Create a new logger for the given type.
    /// - Parameter loggee: The object this logger us for.
    init<T>(_ loggee: T.Type) {
        self.category = String(describing: loggee)
        self.logger = Logger(
            subsystem: Bundle.main.bundleIdentifier!,
            category: self.category
        )
    }

    /// Log a new message. Prefer the named alternative functions where possible. This should only be used when converting between logging providers.
    /// - Parameter level: The level this log corresponds to.
    /// - Parameter msg: The log message itself.
    /// - Parameter alert: True to display this message to the user.
    func log(level: LogLevel, _ msg: String, alert: Bool) {
        self.logger.log(level: OSLogType(level), "\(msg, privacy: .public)")
        guard alert else { return }
        let now = Date.now
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard !Self.shared.alerts.contains(where: { $0.message == msg }) else {
                return
            }
            Self.shared.alerts.append(.init(date: now, category: self.category, level: level, message: msg))
        }
    }

    /// Log an error message to the user.
    /// - Parameter error: The message.
    func error(_ msg: String) { log(level: .error, msg, alert: true) }

    /// Log a warning message.
    /// - Parameter msg: The message.
    /// - Parameter alert: True to show this warning to the user. Defaults to false.
    func warning(_ msg: String, alert: Bool = false) { log(level: .warning, msg, alert: alert) }

    /// Log an informational message.
    /// - Parameter msg: The message.
    func info(_ msg: String) { log(level: .info, msg, alert: false) }

    /// Log and present an informational message to the user.
    /// - Parameter msg: The message.
    func notice(_ msg: String) { log(level: .info, msg, alert: true) }

    /// Log a debug message.
    /// - Parameter msg: The message.
    /// - Parameter alert: True to show this debug message to the user. Defaults to false.
    func debug(_ msg: String, alert: Bool = false) { log(level: .debug, msg, alert: alert) }
}

extension OSLogType {
    /// Convert an application log level to the system log level.
    /// - Parameter level: The application log level.
    init(_ level: DecimusLogger.LogLevel) {
        switch level {
        case .error:
            self = .fault
        case .warning:
            self = .error
        case .info:
            self = .info
        case .debug:
            self = .debug
        }
    }
}
