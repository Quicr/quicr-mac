// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

let microsecondsPerSecond: TimeInterval = 1_000_000

/// Possible errors thrown by ``LowOverheadContainer``.
enum LowOverheadContainerError: LocalizedError {
    /// The container was missing a mandatory field.
    case missingField(NSNumber)
    /// A field's value could not be parsed.
    case unparsableField(NSNumber)

    var errorDescription: String? {
        switch self {
        case .missingField(let field):
            return "Missing mandatory field \(field)"
        case .unparsableField(let field):
            return "Could not parse field \(field)"
        }
    }
}

/// Representation of https://datatracker.ietf.org/doc/draft-mzanaty-moq-loc/
class LowOverheadContainer {
    private let timestampKey: NSNumber = 2
    private let sequenceKey: NSNumber = 4

    /// Contained object's timestamp.
    let timestamp: Date
    /// Contained object's sequence number.
    let sequence: UInt64?
    /// Wire encoded LOC as MoQ object header extension dictionary.
    private(set) var extensions: [NSNumber: Data]

    /// Encode a new LOC from its constituent parts.
    /// - Parameter timestamp: Timestamp of this media.
    /// - Parameter sequence: Sequence number of this media.
    init(timestamp: Date, sequence: UInt64?) {
        self.timestamp = timestamp
        self.sequence = sequence
        var extensions: [NSNumber: Data] = [:]
        var timestamp = UInt64(timestamp.timeIntervalSince1970 * microsecondsPerSecond)
        let timestampData = Data(bytes: &timestamp,
                                 count: MemoryLayout.size(ofValue: timestamp))
        extensions[self.timestampKey] = timestampData
        if let sequence {
            var sequence = sequence
            let sequenceData = Data(bytes: &sequence,
                                    count: MemoryLayout.size(ofValue: sequence))
            extensions[self.sequenceKey] = sequenceData
        }
        self.extensions = extensions
    }

    /// Add a new key-value pair to the container.
    /// - Parameter key: Key to add.
    /// - Parameter value: Value to add.
    func add(key: NSNumber, value: Data) {
        self.extensions[key] = value
    }

    /// Add a new key-value pair to the container.
    /// - Parameter key: Key to add.
    /// - Parameter value: Value to add.
    func add(key: AppHeaderRegistry, value: Data) {
        self.add(key: key.rawValue, value: value)
    }

    /// Get a value from the container.
    /// - Parameter key: Key to retrieve.
    /// - Returns: Value associated with the key, if any.
    func get(key: NSNumber) -> Data? {
        return self.extensions[key]
    }

    /// Get a value from the container.
    /// - Parameter key: Key to retrieve.
    /// - Returns: Value associated with the key, if any.
    func get(key: AppHeaderRegistry) -> Data? {
        self.get(key: key.rawValue)
    }

    /// Parse a LOC from a MoQ header extension dictionary.
    /// - Throws: ``LowOverheadContainerError/missingField`` if a mandatory field is missing.
    init(from extensions: [NSNumber: Data]) throws {
        self.extensions = extensions
        guard let timestampData = extensions[self.timestampKey] else {
            throw LowOverheadContainerError.missingField(self.timestampKey)
        }

        let timestamp = try Self.parse(timestampData, field: self.timestampKey)
        self.timestamp = .init(timeIntervalSince1970: Double(timestamp) / microsecondsPerSecond)
        if let sequenceData = extensions[self.sequenceKey] {
            self.sequence = UInt64(try Self.parse(sequenceData, field: self.sequenceKey))
        } else {
            self.sequence = nil
        }
    }

    static func parse(_ data: Data, field: NSNumber) throws -> any BinaryInteger {
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
            throw LowOverheadContainerError.unparsableField(field)
        }
    }
}
