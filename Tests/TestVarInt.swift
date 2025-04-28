// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Testing
@testable import QuicR

// swiftlint:disable large_tuple

let rfc9000Vectors: [([UInt8], UInt64, Bool)] = [
    ([0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c], 151_288_809_941_952_652, true),
    ([0x9d, 0x7f, 0x3e, 0x7d], 494_878_333, true),
    ([0x7b, 0xbd], 15_293, true),
    ([0x25], 37, true),
    ([0x40, 0x25], 37, false)
]

@Test("QUIC VarInt", arguments: rfc9000Vectors)
func varint(_ vector: ([UInt8], UInt64, Bool)) throws {
    var offset = 0
    let encoded = VarInt(vector.1).toWireFormat()
    if vector.2 {
        #expect(encoded == .init(vector.0))
    }
    let decoded = try VarInt(wireFormat: encoded, bytesRead: &offset)
    #expect(decoded.value == vector.1)
}

// swiftlint:enable large_tuple
