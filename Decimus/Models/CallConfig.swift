import Foundation

/// Configuration for joining a call.
struct CallConfig {
    /// Address of the server.
    var address: String
    /// Publish name, if any.
    var publishName: String?
    ///  Subscribe name, if any.
    var subscribeName: String?
}
