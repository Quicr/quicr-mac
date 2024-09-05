// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

let defaultProtocolPorts: [ProtocolType: UInt16] = [
    .UDP: 33434,
    .QUIC: 33435
]

struct RelayConfig: Codable {
    var address: String = "relay.quicr.ctgpoc.com"
    var connectionProtocol: ProtocolType = .QUIC
    var port: UInt16 = defaultProtocolPorts[.QUIC]!
}
