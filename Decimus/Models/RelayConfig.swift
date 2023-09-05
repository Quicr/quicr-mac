import Foundation

struct RelayConfig: Codable {
    var address: String = "relay.us-west-2.quicr.ctgpoc.com"
    var quicPort: UInt16 = 33435
    var udpPort: UInt16 = 33434
}
