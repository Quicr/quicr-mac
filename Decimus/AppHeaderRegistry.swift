// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

enum AppHeadersRegistry: UInt64 {
    case sequenceNumber = 4
    case energyLevel = 6
    case participantId = 8
    case publishTimestamp = 10

    var nsKey: NSNumber {
        .init(value: self.rawValue)
    }
}

enum AppHeaders {
    case sequenceNumber(UInt64)
    case energyLevel(UInt8)
    case participantId(ParticipantId)
    case publishTimestamp(Date)

    var value: AppHeadersRegistry {
        switch self {
        case .sequenceNumber: .sequenceNumber
        case .energyLevel: .energyLevel
        case .participantId: .participantId
        case .publishTimestamp: .publishTimestamp
        }
    }
}

extension HeaderExtensions {
    func getHeader(_ appHeader: AppHeadersRegistry) throws -> AppHeaders? {
        guard let data = self[appHeader.nsKey] else { return nil }
        switch appHeader {
        case .energyLevel:
            guard let first = data.first else { throw "Invalid" }
            return .energyLevel(first)
        case .participantId:
            guard let int = data.parseInteger() else { throw "Invalid" }
            return .participantId(.init(UInt32(int)))
        case .sequenceNumber:
            guard let int = data.parseInteger() else { throw "Invalid" }
            return .sequenceNumber(UInt64(int))
        case .publishTimestamp:
            guard let microseconds = data.parseInteger() else { throw "Invalid" }
            return .publishTimestamp(Date(timeIntervalSince1970: TimeInterval(microseconds) / microsecondsPerSecond))
        }
    }

    mutating func setHeader(_ key: AppHeaders) throws {
        self[key.value.nsKey] = switch key {
        case .energyLevel(let level):
            .init([level])
        case .participantId(let id):
            withUnsafeBytes(of: id.aggregate) { .init($0) }
        case .sequenceNumber(let number):
            withUnsafeBytes(of: number) { .init($0) }
        case .publishTimestamp(let date):
            withUnsafeBytes(of: UInt64(date.timeIntervalSince1970 * TimeInterval(microsecondsPerSecond))) { .init($0) }
        }
    }
}
