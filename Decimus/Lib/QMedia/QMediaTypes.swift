// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

typealias QuicrNamespace = String
typealias SourceIDType = String

/// Protocol type mappings
enum ProtocolType: UInt8, CaseIterable, Codable, Identifiable, Comparable {
    static func < (lhs: ProtocolType, rhs: ProtocolType) -> Bool {
        return lhs.id < rhs.id
    }

    case UDP = 0
    case QUIC = 1
    var id: UInt8 { rawValue }
}
