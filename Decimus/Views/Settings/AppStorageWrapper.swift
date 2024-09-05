// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

// https://forums.swift.org/t/rawrepresentable-conformance-leads-to-crash/51912/3

import Foundation

struct AppStorageWrapper<Value: Codable> {
    var value: Value
}

extension AppStorageWrapper: RawRepresentable {

    typealias RawValue = String

    var rawValue: RawValue {
        guard
            let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return string
    }

    init?(rawValue: RawValue) {
        guard
            let data = rawValue.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Value.self, from: data)
        else {
            return nil
        }
        value = decoded
    }
}
