import Foundation

/// Configuration for joining a call.
struct CallConfig {
    /// Address of the server.
    var address: String
    /// Port to connect on.
    var port: UInt16
    /// Protocol to use
    var connectionProtocol: QMedia.ProtocolType
}
