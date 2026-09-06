// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

struct TopNH264AccessUnit: Sendable {
    let index: Int
    let isIDR: Bool
    let payload: Data
}

struct TopNH264Fixture: Sendable {
    static let magic = Data([0x51, 0x54, 0x48, 0x31])

    let fps: UInt16
    let width: UInt16
    let height: UInt16
    let accessUnits: [TopNH264AccessUnit]

    static func load(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        var offset = 0

        func readByte() throws -> UInt8 {
            guard offset < data.count else { throw TopNH264FixtureError.truncated(offset) }
            defer { offset += 1 }
            return data[offset]
        }

        func readUInt16() throws -> UInt16 {
            guard data.count - offset >= 2 else { throw TopNH264FixtureError.truncated(offset) }
            let value = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            offset += 2
            return value
        }

        func readUInt32() throws -> UInt32 {
            guard data.count - offset >= 4 else { throw TopNH264FixtureError.truncated(offset) }
            let value = UInt32(data[offset]) << 24 |
                UInt32(data[offset + 1]) << 16 |
                UInt32(data[offset + 2]) << 8 |
                UInt32(data[offset + 3])
            offset += 4
            return value
        }

        guard data.count >= magic.count, data.prefix(magic.count) == magic else {
            throw TopNH264FixtureError.invalid("wrong magic")
        }
        offset = magic.count
        guard try readUInt16() == 1 else { throw TopNH264FixtureError.invalid("unsupported version") }
        let fps = try readUInt16()
        let width = try readUInt16()
        let height = try readUInt16()
        let frameCount = try readUInt16()
        guard fps == 30, width == 320, height == 180, frameCount == 150 else {
            throw TopNH264FixtureError.invalid("unexpected fixture dimensions or frame count")
        }

        var accessUnits: [TopNH264AccessUnit] = []
        accessUnits.reserveCapacity(Int(frameCount))
        for index in 0..<Int(frameCount) {
            let flags = try readByte()
            let length = Int(try readUInt32())
            guard length > 0, data.count - offset >= length else {
                throw TopNH264FixtureError.truncated(offset)
            }
            let payload = Data(data[offset..<(offset + length)])
            offset += length
            let isIDR = flags & 1 != 0
            if index == 0, !isIDR { throw TopNH264FixtureError.invalid("frame zero is not IDR") }
            if index > 0, isIDR { throw TopNH264FixtureError.invalid("later frame is IDR") }
            try validateNALUnits(payload, frameIndex: index)
            accessUnits.append(.init(index: index, isIDR: isIDR, payload: payload))
        }
        guard offset == data.count else { throw TopNH264FixtureError.invalid("trailing bytes") }
        return .init(fps: fps, width: width, height: height, accessUnits: accessUnits)
    }

    private static func validateNALUnits(_ payload: Data, frameIndex: Int) throws {
        var offset = 0
        var types: Set<UInt8> = []
        var hasSlice = false
        while offset < payload.count {
            guard payload.count - offset >= 4 else { throw TopNH264FixtureError.invalid("truncated NAL length") }
            let length = Int(UInt32(payload[offset]) << 24 |
                                UInt32(payload[offset + 1]) << 16 |
                                UInt32(payload[offset + 2]) << 8 |
                                UInt32(payload[offset + 3]))
            offset += 4
            guard length > 0, payload.count - offset >= length else {
                throw TopNH264FixtureError.invalid("invalid NAL length")
            }
            let type = payload[offset] & 0x1F
            types.insert(type)
            hasSlice = hasSlice || type == 1 || type == 5
            offset += length
        }
        guard offset == payload.count, hasSlice else {
            throw TopNH264FixtureError.invalid("frame has no slice")
        }
        if frameIndex == 0 {
            guard types.contains(5), types.contains(7), types.contains(8) else {
                throw TopNH264FixtureError.invalid("frame zero is missing SPS, PPS, or IDR")
            }
        } else if !types.contains(1) {
            throw TopNH264FixtureError.invalid("non-IDR frame has no type-1 slice")
        }
    }
}

enum TopNH264FixtureError: LocalizedError, Equatable {
    case invalid(String)
    case truncated(Int)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .truncated(let offset): return "truncated fixture at byte \(offset)"
        }
    }
}

extension TopNH264Fixture {
    static func loadFromTestBundle() throws -> Self {
        guard let url = Bundle(for: TestTopNClientHarness.self).url(forResource: "topn-gop",
                                                                    withExtension: "qth264") else {
            throw TopNH264FixtureError.invalid("bundled topn-gop.qth264 not found")
        }
        return try load(from: url)
    }
}
