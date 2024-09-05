// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

struct LowOverheadContainer {
    static let microsecondsPerSecond: TimeInterval = 1_000_000
    private let timestampKey: NSNumber = 1
    private let sequenceKey: NSNumber = 2

    let timestamp: Date?
    let sequence: UInt64?
    let extensions: [NSNumber: Data]

    init(timestamp: Date, sequence: UInt64) {
        self.timestamp = timestamp
        self.sequence = sequence
        var timestamp = UInt64(timestamp.timeIntervalSince1970 * LowOverheadContainer.microsecondsPerSecond)
        let timestampData = Data(bytes: &timestamp,
                                 count: MemoryLayout.size(ofValue: timestamp))
        var sequence = sequence
        let sequenceData = Data(bytes: &sequence,
                                count: MemoryLayout.size(ofValue: sequence))
        self.extensions = [
            self.timestampKey: timestampData,
            self.sequenceKey: sequenceData
        ]
    }

    init(from extensions: [NSNumber: Data]) {
        self.extensions = extensions
        let timestamp: UInt64
        if let timestampData = extensions[self.timestampKey] {
            timestamp = timestampData.withUnsafeBytes {
                return $0.load(as: UInt64.self)
            }
            self.timestamp = .init(timeIntervalSince1970: Double(timestamp) / Self.microsecondsPerSecond)
        } else {
            self.timestamp = nil
        }
        if let sequenceData = extensions[self.sequenceKey] {
            self.sequence = sequenceData.withUnsafeBytes {
                return $0.load(as: UInt64.self)
            }
        } else {
            self.sequence = nil
        }
    }
}
