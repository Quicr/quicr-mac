// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Configuration for joining a call.
struct CallConfig: Hashable {
    /// Address of the server.
    var address: String
    /// Port to connect on.
    var port: UInt16
    /// Protocol to use in qmedia
    var connectionProtocol: ProtocolType
    /// Email address of the user joining the call
    var email: String = ""
    /// Conference ID to join
    var conferenceID: UInt32 = 0
}
