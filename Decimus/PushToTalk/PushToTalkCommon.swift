// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

enum MessageType: UInt8 {
    case audio = 0x1
}

struct ChunkMessage {
    let type: MessageType
    let isLastChunk: Bool
    let data: Data

    var size: Int {
        MemoryLayout<UInt8>.size * 2 + MemoryLayout<UInt32>.size + self.data.count
    }

    init(type: MessageType, isLastChunk: Bool, data: Data) {
        self.type = type
        self.isLastChunk = isLastChunk
        self.data = data
    }

    init(from data: Data) throws {
        let headerSize = (MemoryLayout<UInt8>.size * 2) + MemoryLayout<UInt32>.size
        guard data.count >= headerSize else { throw "Not enough data for header" }
        guard let type = MessageType(rawValue: data[0]) else { throw "Unsupported Message Type" }
        self.type = type
        self.isLastChunk = data[1] == 1
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt32.self) }
        guard data.count >= Int(count) + headerSize else { throw "Not enough data for declared size" }
        self.data = data[headerSize..<Int(count) + headerSize]
    }

    func encode(into: inout Data) {
        into.append(self.type.rawValue)
        into.append(self.isLastChunk ? 1 : 0)
        let count = UInt32(self.data.count)
        withUnsafeBytes(of: count) { into.append(contentsOf: $0) }
        into.append(self.data)
    }
}
