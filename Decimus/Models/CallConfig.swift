// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Configuration for joining a call.
struct CallConfig {
    /// Address of the server.
    var address: String
    /// Email address of the user joining the call
    var email: String = ""
    /// The join type.
    var joinType: JoinType
}
