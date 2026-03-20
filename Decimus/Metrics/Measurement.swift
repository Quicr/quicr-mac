// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import Synchronization

struct Point {
    let fieldName: String
    let value: AnyObject
    let tags: [String: String]?
}

typealias Fields = [Date?: [Point]]

protocol Measurement: AnyObject, Sendable {
    var id: UUID { get }
    var name: String { get }
    var tags: [String: String] { get }
    func record(field: String, value: AnyObject, timestamp: Date?, tags: [String: String]?)
    func record(field: String, value: Double, timestamp: Date?, tags: [String: String]?)
    func drain() -> Fields
}

extension Measurement {
    func record(field: String, value: AnyObject, timestamp: Date?) {
        record(field: field, value: value, timestamp: timestamp, tags: nil)
    }

    func record(field: String, value: Double, timestamp: Date?) {
        record(field: field, value: value, timestamp: timestamp, tags: nil)
    }
}

/// Base class for all measurements. Provides Mutex-backed storage for fields.
/// Subclasses provide `name`, `tags`, and domain-specific convenience methods.
/// Mutable counters in subclasses should use Atomic<UInt64> rather than stored vars.
class MeasurementBase: @unchecked Sendable, Measurement {
    let id = UUID()
    let name: String
    private let _tags: [String: String]
    var tags: [String: String] { _tags }

    private let storage = Mutex<Fields>([:])

    init(name: String, tags: [String: String] = [:]) {
        self.name = name
        self._tags = tags
    }

    func record(field: String, value: AnyObject, timestamp: Date?, tags: [String: String]? = nil) {
        storage.withLock { fields in
            if fields[timestamp] == nil { fields[timestamp] = [] }
            fields[timestamp]!.append(.init(fieldName: field, value: value, tags: tags))
        }
    }

    // Existing behaviour preserved: adds .ulpOfOne to integer-valued doubles
    // to force InfluxDB float field typing.
    func record(field: String, value: Double, timestamp: Date?, tags: [String: String]? = nil) {
        let floatValue: TimeInterval
        if value == 0 || Int(exactly: value) != nil {
            floatValue = value + .ulpOfOne
        } else {
            floatValue = value
        }
        record(field: field, value: floatValue as AnyObject, timestamp: timestamp, tags: tags)
    }

    func drain() -> Fields {
        storage.withLock { fields in
            let result = fields
            fields.removeAll(keepingCapacity: true)
            return result
        }
    }
}
