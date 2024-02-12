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
        let level: OSLogType
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

    func log(level: OSLogType, _ msg: String, alert: Bool = false) {
        logger.log(level: level, "\(msg, privacy: .public)")
        guard alert else { return }
        let now = Date.now
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            Self.shared.alerts.append(.init(date: now, category: self.category, level: level, message: msg))
        }
    }

    func log(level: LogLevel, _ msg: String, alert: Bool = false) {
        log(level: .init(level), msg, alert: alert)
    }

    func critical(_ msg: String) { log(level: OSLogType.fault, msg, alert: true) }
    func error(_ msg: String, alert: Bool = false) { log(level: OSLogType.error, msg, alert: alert) }
    func warning(_ msg: String, alert: Bool = false) { log(level: OSLogType.error, msg, alert: alert) }
    func info(_ msg: String) { log(level: OSLogType.info, msg) }
    func notice(_ msg: String, alert: Bool = false) { log(level: OSLogType.info, msg, alert: alert) }
    func debug(_ msg: String, alert: Bool = false) { log(level: OSLogType.debug, msg, alert: alert) }
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
