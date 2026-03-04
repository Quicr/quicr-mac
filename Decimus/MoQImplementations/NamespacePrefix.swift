// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

// MoQ Namespace Prefix.
struct NamespacePrefix: Hashable, CustomStringConvertible {
    let elements: [Data]

    init(_ elements: [Data]) {
        self.elements = elements
    }

    init(_ strings: [String]) {
        self.elements = strings.map { Data($0.utf8) }
    }

    var description: String {
        let strings = elements.compactMap { String(data: $0, encoding: .utf8) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        if let encoded = try? encoder.encode(strings),
           let result = String(data: encoded, encoding: .utf8) {
            return result
        }
        return strings.joined(separator: "/")
    }
}
