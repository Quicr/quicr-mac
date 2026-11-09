// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

enum AppHeadersRegistry: UInt64 {
    case sequenceNumber = 0x3800
    case participantId = 0x3804
    case publishTimestamp = 0x3806
    case audioActivityIndicator = 0x3808

    var nsKey: NSNumber {
        .init(value: self.rawValue)
    }
}

enum AppHeaders {
    case sequenceNumber(UInt64)
    case participantId(ParticipantId)
    case publishTimestamp(Date)
    case audioActivityIndicator(UInt8)

    var value: AppHeadersRegistry {
        switch self {
        case .sequenceNumber: .sequenceNumber
        case .participantId: .participantId
        case .publishTimestamp: .publishTimestamp
        case .audioActivityIndicator: .audioActivityIndicator
        }
    }
}

extension HeaderExtensions {
    func getHeader(_ appHeader: AppHeadersRegistry) throws -> AppHeaders? {
        guard let dataArray = self[appHeader.nsKey], let data = dataArray.first else { return nil }
        switch appHeader {
        case .participantId:
            guard let int = data.parseInteger() else { throw "Invalid" }
            return .participantId(.init(UInt32(int)))
        case .sequenceNumber:
            guard let int = data.parseInteger() else { throw "Invalid" }
            return .sequenceNumber(UInt64(int))
        case .publishTimestamp:
            guard let microseconds = data.parseInteger() else { throw "Invalid" }
            return .publishTimestamp(Date(timeIntervalSince1970: TimeInterval(microseconds) / microsecondsPerSecond))
        case .audioActivityIndicator:
            guard let first = data.first else { throw "Invalid" }
            return .audioActivityIndicator(first)
        }
    }

    mutating func setHeader(_ key: AppHeaders) throws {
        let data = switch key {
        case .participantId(let id):
            withUnsafeBytes(of: id.aggregate) { Data($0) }
        case .sequenceNumber(let number):
            withUnsafeBytes(of: number) { Data($0) }
        case .publishTimestamp(let date):
            withUnsafeBytes(of: UInt64(date.timeIntervalSince1970 * TimeInterval(microsecondsPerSecond))) { Data($0) }
        case .audioActivityIndicator(let value):
            Data([value])
        }
        let nsKey = key.value.nsKey
        if var existing = self[nsKey] {
            existing.append(data)
            self[nsKey] = existing
        } else {
            self[nsKey] = [data]
        }
    }
}
