// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

struct Point {
    let fieldName: String
    let value: AnyObject
    let tags: [String: String]?
}

typealias Fields = [Date?: [Point]]

protocol Measurement: AnyObject, Actor {
    nonisolated var id: UUID { get }
    var name: String { get }
    var fields: Fields { get set }
    var tags: [String: String] { get }
    func record(field: String, value: AnyObject, timestamp: Date?, tags: [String: String]?)
}

extension Measurement {
    func record(field: String, value: AnyObject, timestamp: Date?, tags: [String: String]? = nil) {
        if fields[timestamp] == nil {
            fields[timestamp] = []
        }
        fields[timestamp]!.append(.init(fieldName: field, value: value, tags: tags))
    }

    func record(field: String, value: Double, timestamp: Date?, tags: [String: String]? = nil) {
        let floatValue: TimeInterval
        if value == 0 || Int(exactly: value) != nil {
            floatValue = value + .ulpOfOne
        } else {
            floatValue = value
        }
        record(field: field, value: floatValue as AnyObject, timestamp: timestamp, tags: tags)
    }

    func clear() {
        fields.removeAll(keepingCapacity: true)
    }
}
