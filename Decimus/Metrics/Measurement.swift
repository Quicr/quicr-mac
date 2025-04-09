// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

struct Point {
    let fieldName: String
    let value: AnyObject
    let tags: [String: String]?
}

typealias Fields = [Date?: [Point]]

class Measurement {
    let id = UUID()
    let name: String
    private let fields = Mutex<Fields>([:])
    var tags: [String: String] = [:]

    init(name: String, tags: [String: String] = [:]) {
        self.name = name
        self.tags = tags
    }

    func getFields() -> Fields { self.fields.get() }

    func record(field: String, value: AnyObject, timestamp: Date?, tags: [String: String]? = nil) {
        self.fields.withLock { fields in
            if fields[timestamp] == nil {
                fields[timestamp] = []
            }
            fields[timestamp]!.append(.init(fieldName: field, value: value, tags: tags))
        }
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
        self.fields.withLock { $0.removeAll(keepingCapacity: true) }
    }
}
