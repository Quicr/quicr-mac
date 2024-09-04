// Allows CoreFoundation return codes to be thrown as Swift errors.
extension CoreFoundation.OSStatus: Swift.Error { }

/// Localized error wrapper for a CF OSStatus.
struct OSStatusError: LocalizedError {
    /// Full error message to be presented.
    var errorDescription: String?

    init(error: OSStatus, message: String) {
        self.errorDescription = "\(message): \(error)"
    }

    /// Helper to throw an ``OSStatusError`` if the given closure returns a non-0 OSStatus.
    /// - Parameter message: Identifier for this block to be included in any error.
    /// - Parameter call: OSStatus returning closure to execute and check.
    /// - Throws: An ``OSStatusError`` if the `call` closure returns a non-0 OSStatus.
    static func checked(_ message: String, _ call: () -> OSStatus) throws {
        let result = call()
        guard result == .zero else {
            throw OSStatusError(error: result, message: message)
        }
    }
}
