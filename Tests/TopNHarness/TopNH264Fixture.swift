// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

enum TopNVideoQuality: String, CaseIterable, Codable, Hashable, Sendable {
    case p1080 = "1080p"
    case p720 = "720p"
    case p360 = "360p"

    var width: UInt16 {
        switch self {
        case .p1080: 1920
        case .p720: 1280
        case .p360: 640
        }
    }

    var height: UInt16 {
        switch self {
        case .p1080: 1080
        case .p720: 720
        case .p360: 360
        }
    }

    var bitrateKbps: Int {
        switch self {
        case .p1080: 4000
        case .p720: 2000
        case .p360: 800
        }
    }

    var qualityProfile: String {
        "h264,width=\(self.width),height=\(self.height),fps=30,br=\(self.bitrateKbps)"
    }

    func subscribeNamespace(meetingID: String) -> [String] {
        ["meetings.wbx.com", meetingID, "video", self.rawValue]
    }

    func publicationNamespace(meetingID: String, participant: TopNParticipantID) -> [String] {
        self.subscribeNamespace(meetingID: meetingID) + [participant.rawValue]
    }
}

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

    fileprivate static func validateNALUnits(_ payload: Data, frameIndex: Int) throws {
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

struct TopNH264FixtureSet: Sendable {
    let fixtures: [TopNVideoQuality: TopNH264Fixture]

    subscript(quality: TopNVideoQuality) -> TopNH264Fixture {
        self.fixtures[quality]!
    }

    static func load(from url: URL) throws -> Self {
        try self.load(data: Data(contentsOf: url))
    }

    static func load(data: Data) throws -> Self {
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

        guard data.count >= TopNH264Fixture.magic.count,
              data.prefix(TopNH264Fixture.magic.count) == TopNH264Fixture.magic else {
            throw TopNH264FixtureError.invalid("wrong magic")
        }
        offset = TopNH264Fixture.magic.count
        guard try readUInt16() == 2 else {
            throw TopNH264FixtureError.invalid("unsupported fixture-set version")
        }
        let fixtureCount = Int(try readUInt16())
        guard fixtureCount == TopNVideoQuality.allCases.count else {
            throw TopNH264FixtureError.invalid(
                "expected \(TopNVideoQuality.allCases.count) quality fixtures, found \(fixtureCount)")
        }

        var fixtures: [TopNVideoQuality: TopNH264Fixture] = [:]
        for _ in 0..<fixtureCount {
            let qualityIndex = Int(try readByte())
            guard TopNVideoQuality.allCases.indices.contains(qualityIndex) else {
                throw TopNH264FixtureError.invalid("unknown quality index \(qualityIndex)")
            }
            let quality = TopNVideoQuality.allCases[qualityIndex]
            guard fixtures[quality] == nil else {
                throw TopNH264FixtureError.invalid("duplicate \(quality.rawValue) fixture")
            }
            let fps = try readUInt16()
            let width = try readUInt16()
            let height = try readUInt16()
            let frameCount = Int(try readUInt16())
            guard fps == 30, width == quality.width, height == quality.height, frameCount == 150 else {
                throw TopNH264FixtureError.invalid("unexpected \(quality.rawValue) fixture metadata")
            }

            var accessUnits: [TopNH264AccessUnit] = []
            accessUnits.reserveCapacity(frameCount)
            for index in 0..<frameCount {
                let flags = try readByte()
                let length = Int(try readUInt32())
                guard length > 0, data.count - offset >= length else {
                    throw TopNH264FixtureError.truncated(offset)
                }
                let payload = Data(data[offset..<(offset + length)])
                offset += length
                let isIDR = flags & 1 != 0
                if index == 0, !isIDR {
                    throw TopNH264FixtureError.invalid("\(quality.rawValue) frame zero is not IDR")
                }
                if index > 0, isIDR {
                    throw TopNH264FixtureError.invalid("\(quality.rawValue) later frame is IDR")
                }
                try TopNH264Fixture.validateNALUnits(payload, frameIndex: index)
                accessUnits.append(.init(index: index, isIDR: isIDR, payload: payload))
            }
            fixtures[quality] = .init(fps: fps, width: width, height: height, accessUnits: accessUnits)
        }
        guard offset == data.count else { throw TopNH264FixtureError.invalid("trailing bytes") }
        return .init(fixtures: fixtures)
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

extension TopNH264FixtureSet {
    static func loadFromTestBundle() throws -> Self {
        guard let url = Bundle(for: TestTopNClientHarness.self).url(forResource: "topn-gop",
                                                                    withExtension: "qth264") else {
            throw TopNH264FixtureError.invalid("bundled topn-gop.qth264 not found")
        }
        return try load(from: url)
    }
}
