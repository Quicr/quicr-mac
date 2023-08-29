import Foundation

struct RelayConfig: Codable {
    var address: String = "relay.us-west-2.quicr.ctgpoc.com"
    var ports: [ProtocolType: UInt16] = [
        .QUIC: 33435,
        .UDP: 33434
    ]
}

extension AppStorageWrapper<RelayConfig> {
    init?(rawValue: RawValue) {
        guard
            let data = rawValue.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Value.self, from: data)
        else {
            return nil
        }
        value = decoded
        value.ports.merge(RelayConfig().ports) { (current, _) in current }
    }
}
