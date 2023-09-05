import Foundation

let defaultProtocolPorts: [ProtocolType: UInt16] = [
    .UDP: 33434,
    .QUIC: 33435
]

struct RelayConfig: Codable {
    var address: String = "relay.us-west-2.quicr.ctgpoc.com"
    var connectionProtocol: ProtocolType = .QUIC
    var port: UInt16 = defaultProtocolPorts[.QUIC]!
}
