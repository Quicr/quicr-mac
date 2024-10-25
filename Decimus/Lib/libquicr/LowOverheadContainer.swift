// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

let microsecondsPerSecond: TimeInterval = 1_000_000

/// Possible errors thrown by ``LowOverheadContainer``.
enum LowOverheadContainerError: Error {
    /// The container was missing a mandatory field.
    case missingField
}

/// Representation of https://datatracker.ietf.org/doc/draft-mzanaty-moq-loc/
struct LowOverheadContainer {
    private let timestampKey: NSNumber = 1
    private let sequenceKey: NSNumber = 2

    /// Contained object's timestamp.
    let timestamp: Date
    /// Contained object's sequence number.
    let sequence: UInt64
    /// Wire encoded LOC as MoQ object header extension dictionary.
    let extensions: [NSNumber: Data]

    /// Encode a new LOC from its constituent parts.
    /// - Parameter timestamp: Timestamp of this media.
    /// - Parameter sequence: Sequence number of this media.
    init(timestamp: Date, sequence: UInt64) {
        self.timestamp = timestamp
        self.sequence = sequence
        var timestamp = UInt64(timestamp.timeIntervalSince1970 * microsecondsPerSecond)
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

    /// Parse a LOC from a MoQ header extension dictionary.
    /// - Throws: ``LowOverheadContainerError/missingField`` if a mandatory field is missing.
    init(from extensions: [NSNumber: Data]) throws {
        self.extensions = extensions
        guard let timestampData = extensions[self.timestampKey],
              let sequenceData = extensions[self.sequenceKey] else {
            throw LowOverheadContainerError.missingField
        }

        let timestamp: UInt64 = timestampData.withUnsafeBytes {
            return $0.load(as: UInt64.self)
        }
        self.timestamp = .init(timeIntervalSince1970: Double(timestamp) / microsecondsPerSecond)
        self.sequence = sequenceData.withUnsafeBytes {
            return $0.load(as: UInt64.self)
        }
    }
}
