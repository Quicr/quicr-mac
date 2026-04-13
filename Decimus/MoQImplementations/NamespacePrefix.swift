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
        elements.map { moqEncodeTuple($0) }.joined(separator: "-")
    }
}
