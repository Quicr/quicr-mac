// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

enum MessageType: UInt8 {
    case audio = 0x1
    case aiAudio = 0x2
    case aiText = 0x3
}

enum ContentType: UInt8 {
    case audio = 0
    case json = 1
}

struct ChunkMessage {
    let type: MessageType
    let isLastChunk: Bool
    let data: Data
    let requestId: UInt32?
    let contentType: ContentType?

    var size: Int {
        let base = MemoryLayout<UInt8>.size * 2 + MemoryLayout<UInt32>.size + self.data.count
        var size = base
        if self.requestId != nil {
            size += MemoryLayout<UInt32>.size
        }
        if self.contentType != nil {
            size += MemoryLayout<UInt8>.size
        }
        return size
    }

    static func headerSize(_ type: MessageType) -> Int {
        switch type {
        case .audio:
            1 + 1 + 4
        case .aiAudio:
            1 + 4 + 1 + 4
        case .aiText:
            1 + 4 + 1 + 1 + 4
        }
    }

    init(type: MessageType, isLastChunk: Bool, data: Data, requestId: UInt32? = nil) {
        self.type = type
        self.isLastChunk = isLastChunk
        self.data = data
        self.requestId = requestId
        self.contentType = nil
    }

    init(from data: Data) throws {
        guard data.count >= 1 else { throw "Not enough data for header type" }
        var offset = 0
        guard let type = MessageType(rawValue: data[offset]) else { throw "Unsupported Message Type" }
        self.type = type
        offset += MemoryLayout<UInt8>.size
        let requiredSize = Self.headerSize(type)
        guard data.count >= requiredSize else { throw "Not enough data for header" }
        switch type {
        case .aiAudio:
            let requestId = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            self.requestId = requestId
            offset += MemoryLayout<UInt32>.size
            self.contentType = nil
        case .aiText:
            let requestId = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            self.requestId = requestId
            offset += MemoryLayout<UInt32>.size
            self.contentType = .init(rawValue: data[offset])
            offset += MemoryLayout<UInt8>.size
        case .audio:
            self.requestId = nil
            self.contentType = nil
        }
        self.isLastChunk = data[offset] == 1
        offset += MemoryLayout<UInt8>.size
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        guard data.count >= Int(count) + requiredSize else { throw "Not enough data for declared size" }
        self.data = data[requiredSize..<Int(count) + requiredSize]
    }

    func encode(into: inout Data) {
        into.append(self.type.rawValue)
        if self.type == .aiAudio {
            withUnsafeBytes(of: self.requestId!) { into.append(contentsOf: $0) }
        }
        into.append(self.isLastChunk ? 1 : 0)
        let count = UInt32(self.data.count)
        withUnsafeBytes(of: count) { into.append(contentsOf: $0) }
        into.append(self.data)
    }
}
