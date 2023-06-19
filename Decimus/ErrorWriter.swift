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

protocol ErrorWriter {
    func writeError(_ message: String)
}
