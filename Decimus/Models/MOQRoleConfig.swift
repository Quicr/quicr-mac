// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Default ports for each supported protocol.
let defaultMOQRole: [MOQRoleType: UInt16] = [
    .PUBLISHER: 0,
    .SUBSCRIBER: 1,
    .PUBSUB: 2
]

/// Connection details for a MoQ relay.
struct MOQRoleConfig: Codable {
    /// default MOQ Role
    var moqRole: UInt16 = defaultMOQRole[.PUBSUB]!
}
