// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

let defaultUrl = URL(string: "moq://relay.quicr.io:33435")!

/// Connection details for a MoQ relay.
struct RelayConfig: Codable {
    static let defaultsKey = "relay_1"
    /// FQDN.
    var address: URL = defaultUrl
}
