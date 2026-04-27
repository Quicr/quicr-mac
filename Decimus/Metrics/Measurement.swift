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

/// Mutex-backed storage shared by every Measurement. Holding this by composition
/// (rather than inheriting from a base class) lets concrete measurements be `final`
/// and get real `Sendable` conformance, with @unchecked localised here where
/// `AnyObject` field values force it.
final class MeasurementStorage: Sendable {
    let id = UUID()
    private let fields = Mutex<Fields>([:])

    func record(field: String, value: AnyObject, timestamp: Date?, tags: [String: String]?) {
        self.fields.withLock { f in
            if f[timestamp] == nil { f[timestamp] = [] }
            f[timestamp]!.append(.init(fieldName: field, value: value, tags: tags))
        }
    }

    func drain() -> Fields {
        self.fields.withLock { f in
            let r = f
            f.removeAll(keepingCapacity: true)
            return r
        }
    }
}

protocol MetricsMeasurement: AnyObject, Sendable {
    var storage: MeasurementStorage { get }
    var name: String { get }
    var tags: [String: String] { get }
}

extension MetricsMeasurement {
    var id: UUID { self.storage.id }

    func record(field: String, value: AnyObject, timestamp: Date?, tags: [String: String]? = nil) {
        self.storage.record(field: field, value: value, timestamp: timestamp, tags: tags)
    }

    /// Existing behaviour preserved: adds `.ulpOfOne` to integer-valued doubles to
    /// force InfluxDB float field typing.
    func record(field: String, value: Double, timestamp: Date?, tags: [String: String]? = nil) {
        let floatValue: TimeInterval
        if value == 0 || Int(exactly: value) != nil {
            floatValue = value + .ulpOfOne
        } else {
            floatValue = value
        }
        self.record(field: field, value: floatValue as AnyObject, timestamp: timestamp, tags: tags)
    }

    func drain() -> Fields { self.storage.drain() }
}
