// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Connection details for a MoQ relay.
struct RelayConfig: Codable {
    /// FQDN.
    var address: String = "moq://us-ord-1.moqx.akaleapi.net:4433/moq-relay"
    /// mDNS Type for lookup.
    var mDNSType: String = "_laps._udp"
    /// True if we should use mDNS to fill relay info.
    var usemDNS = true
}
