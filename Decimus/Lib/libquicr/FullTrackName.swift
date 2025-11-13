// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Possible errors raised by ``FullTrackName``.
enum FullTrackNameError: Error {
    /// A ``FullTrackName`` could not constructed or parsed into a `String`.
    case parseError
}

/// A MoQ full track name identifies a track within a namespace.
class FullTrackName: QFullTrackName, Hashable, CustomStringConvertible {
    let description: String

    static func == (lhs: FullTrackName, rhs: FullTrackName) -> Bool {
        lhs.nameSpace == rhs.nameSpace && lhs.name == rhs.name
    }

    /// The namespace portion of the full track name.
    let nameSpace: [Data]
    /// The name portion of the full track name.
    let name: Data

    /// Construct a full track name from UTF8 string components.
    /// - Parameter namespace: UTF8 string namespace array.
    /// - Parameter name: UTF8 string name.
    /// - Throws: ``FullTrackNameError/parseError`` if strings are not UTF8.
    init(namespace: [String], name: String) throws {
        var components: [Data] = []
        for element in namespace {
            guard let bytes = element.data(using: .utf8) else {
                throw FullTrackNameError.parseError
            }
            components.append(bytes)
        }
        self.nameSpace = components
        guard let nameData = name.data(using: .utf8) else {
            throw FullTrackNameError.parseError
        }
        self.name = nameData
        self.description = Self.resolveDescription(inNamespace: namespace, inName: name)
    }

    init(_ ftn: QFullTrackName) {
        self.nameSpace = ftn.nameSpace
        self.name = ftn.name
        self.description = Self.resolveDescription(inNamespace: self.nameSpace, inName: self.name)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.name)
        hasher.combine(self.nameSpace)
    }

    func matchesPrefix(prefix: [Data]) -> Bool {
        self.nameSpace.starts(with: prefix)
    }

    private static func resolveDescription(inNamespace: [Data], inName: Data) -> String {
        var namespace: [String] = []
        for element in inNamespace {
            if let str = String(data: element, encoding: .utf8) {
                namespace.append(str)
            } else {
                namespace.append("<invalid utf8>")
            }
        }
        let name = String(data: inName, encoding: .utf8) ?? "<invalid utf8>"
        return Self.resolveDescription(inNamespace: namespace, inName: name)
    }

    private static func resolveDescription(inNamespace: [String], inName: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let encoded = try? encoder.encode(inNamespace)
        let desc = if let encoded {
            String(data: encoded, encoding: .utf8) ?? "<invalid utf8>"
        } else {
            "<encoding error>"
        }
        return inName.isEmpty ? desc : "\(desc):\(inName)"
    }
}

extension Profile {
    func getFullTrackName() throws -> FullTrackName {
        try .init(namespace: self.namespace, name: self.name ?? "")
    }
}
