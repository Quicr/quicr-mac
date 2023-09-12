import os
import OSLog

struct OSStatusError: LocalizedError {
    let error: OSStatus
    let message: String
    var errorDescription: String?

    init(error: OSStatus, message: String) {
        self.error = error
        self.message = message
        self.errorDescription = "\(message): \(error)"
    }

    static func checked(_ message: String, _ call: () -> OSStatus) throws {
        let result = call()
        guard result == .zero else {
            throw OSStatusError(error: result, message: message)
        }
    }
}

class DecimusLogger {
    private let logger: Logger
    private let category: String

    enum LogLevel {
        case fault
        case error
        case warning
        case info
        case debug
        case trace
    }

    struct DecimusLogEntry: Identifiable {
        let id = UUID()

        let date: Date
        let category: String
        let level: LogLevel
        let message: String
    }

    class ObservableLogs: ObservableObject {
        @Published var logs: [DecimusLogEntry] = []
        @Published var alerts: [DecimusLogEntry] = []
    }
    static let shared = ObservableLogs()

    init<T>(_ loggee: T.Type) {
        self.category = String(describing: loggee)
        self.logger = Logger(
            subsystem: Bundle.main.bundleIdentifier!,
            category: category
        )
    }

    func log(level: LogLevel, _ msg: String, alert: Bool = false) {
        let now = Date.now
        logger.log(level: OSLogType(level), "\(msg, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            Self.shared.logs.append(.init(date: now, category: self.category, level: level, message: msg))
            if alert {
                Self.shared.alerts.append(.init(date: now, category: self.category, level: .info, message: msg))
            }
        }
    }

    func log(_ msg: String, alert: Bool = false) {
        let now = Date.now
        logger.log("\(msg)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            Self.shared.logs.append(.init(date: now, category: self.category, level: .info, message: msg))
            if alert {
                Self.shared.alerts.append(.init(date: now, category: self.category, level: .info, message: msg))
            }
        }
    }

    func fault(_ msg: String, alert: Bool = false) { log(level: .fault, msg, alert: alert) }
    func critical(_ msg: String, alert: Bool = false) { fault(msg, alert: alert) }
    func error(_ msg: String, alert: Bool = false) { log(level: .error, msg, alert: alert) }
    func warning(_ msg: String, alert: Bool = false) { log(level: .warning, msg, alert: alert) }
    func info(_ msg: String) { log(level: .info, msg) }
    func notice(_ msg: String) { log(msg) }
    func debug(_ msg: String, alert: Bool = false) { log(level: .debug, msg, alert: alert) }
    func trace(_ msg: String, alert: Bool = false) { log(level: .trace, msg, alert: alert) }
}

extension OSLogType {
    init(_ level: DecimusLogger.LogLevel) {
        switch level {
        case .fault:
            self = .fault
        case .error, .warning:
            self = .error
        case .info:
            self = .info
        case .debug, .trace:
            self = .debug
        }
    }
}
