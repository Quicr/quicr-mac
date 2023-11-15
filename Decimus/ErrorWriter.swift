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

    enum LogLevel: UInt8 {
        case critical
        case error
        case warning
        case info
        case debug
    }

    struct DecimusLogEntry: Identifiable {
        let id = UUID()

        let date: Date
        let category: String
        let level: LogLevel
        let message: String
    }

    class ObservableLogs: ObservableObject {
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
            guard alert else { return }
            Self.shared.alerts.append(.init(date: now, category: self.category, level: level, message: msg))
        }
    }

    func log(_ msg: String, alert: Bool = false) {
        let now = Date.now
        logger.log("\(msg)")

#if DEBUG
        DispatchQueue.main.async { [weak self] in
            guard let self = self, alert else { return }
            Self.shared.alerts.append(.init(date: now, category: self.category, level: .info, message: msg))
        }
#endif
    }

    func critical(_ msg: String) { log(level: .critical, msg, alert: true) }
    func error(_ msg: String, alert: Bool = false) { log(level: .error, msg, alert: alert) }
    func warning(_ msg: String, alert: Bool = false) { log(level: .warning, msg, alert: alert) }
    func info(_ msg: String) { log(level: .info, msg) }
    func notice(_ msg: String, alert: Bool = false) { log(level: .info, msg, alert: alert) }
    func debug(_ msg: String, alert: Bool = false) { log(level: .debug, msg, alert: alert) }
}

extension OSLogType {
    init(_ level: DecimusLogger.LogLevel) {
        switch level {
        case .critical:
            self = .fault
        case .error, .warning:
            self = .error
        case .info:
            self = .info
        case .debug:
            self = .debug
        }
    }
}
