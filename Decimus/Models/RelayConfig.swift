import Foundation

struct RelayConfig: Codable {
    var address: String = "relay.us-west-2.quicr.ctgpoc.com"
    var ports: [ProtocolType: UInt16] = [
        .QUIC: 33435,
        .UDP: 33434
    ]
}
