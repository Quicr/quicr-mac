// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

let microsecondsPerSecond: TimeInterval = 1_000_000

/// Possible errors thrown by ``LowOverheadContainer``.
enum LowOverheadContainerError: Error {
    /// The container was missing a mandatory field.
    case missingField
    /// A field's value could not be parsed.
    case unparsableField
}

/// Representation of https://datatracker.ietf.org/doc/draft-mzanaty-moq-loc/
class LowOverheadContainer {
    private let timestampKey: NSNumber = 2
    private let sequenceKey: NSNumber = 4

    /// Contained object's timestamp.
    let timestamp: Date
    /// Contained object's sequence number.
    let sequence: UInt64
    /// Wire encoded LOC as MoQ object header extension dictionary.
    private(set) var extensions: [NSNumber: Data]

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

    /// Add a new key-value pair to the container.
    /// - Parameter key: Key to add.
    /// - Parameter value: Value to add.
    func add(key: NSNumber, value: Data) {
        self.extensions[key] = value
    }

    /// Get a value from the container.
    /// - Parameter key: Key to retrieve.
    /// - Returns: Value associated with the key, if any.
    func get(key: NSNumber) -> Data? {
        return self.extensions[key]
    }

    /// Parse a LOC from a MoQ header extension dictionary.
    /// - Throws: ``LowOverheadContainerError/missingField`` if a mandatory field is missing.
    init(from extensions: [NSNumber: Data]) throws {
        self.extensions = extensions
        guard let timestampData = extensions[self.timestampKey],
              let sequenceData = extensions[self.sequenceKey] else {
            throw LowOverheadContainerError.missingField
        }

        let timestamp = try Self.parse(timestampData)
        self.timestamp = .init(timeIntervalSince1970: Double(timestamp) / microsecondsPerSecond)
        self.sequence = UInt64(try Self.parse(sequenceData))
    }

    static func parse(_ data: Data) throws -> any BinaryInteger {
        switch data.count {
        case MemoryLayout<UInt64>.size:
            data.withUnsafeBytes {
                $0.loadUnaligned(as: UInt64.self)
            }
        case MemoryLayout<UInt32>.size:
            data.withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            }
        case MemoryLayout<UInt16>.size:
            data.withUnsafeBytes {
                $0.loadUnaligned(as: UInt16.self)
            }
        case MemoryLayout<UInt8>.size:
            data.withUnsafeBytes {
                $0.loadUnaligned(as: UInt8.self)
            }
        default:
            throw LowOverheadContainerError.unparsableField
        }
    }
}
