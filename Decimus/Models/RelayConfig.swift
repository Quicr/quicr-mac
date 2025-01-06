// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Default ports for each supported protocol.
let defaultProtocolPorts: [ProtocolType: UInt16] = [
    .UDP: 33434,
    .QUIC: 33435
]

/// Connection details for a MoQ relay.
struct RelayConfig: Codable {
    /// FQDN.
    var address: String = "relay.quicr.ctgpoc.com"
    /// Protocol to use for the connection.
    var connectionProtocol: ProtocolType = .QUIC
    /// Port to connect on.
    var port: UInt16 = defaultProtocolPorts[.QUIC]!
}
