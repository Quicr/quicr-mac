// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Possible errors raised by ``FullTrackName``.
enum FullTrackNameError: Error {
    /// A ``FullTrackName`` could not constructed or parsed into a `String`.
    case parseError
}

/// A MoQ full track name identifies a track within a namespace.
class FullTrackName: QFullTrackName, Hashable {
    static func == (lhs: FullTrackName, rhs: FullTrackName) -> Bool {
        lhs.nameSpace == rhs.nameSpace && lhs.name == rhs.name
    }

    /// The namespace portion of the full track name.
    let nameSpace: [Data]
    /// The name portion of the full track name.
    let name: Data

    /// Construct a full track name from UTF8 string components.
    /// - Parameter namespace: UTF8 string namespace.
    /// - Parameter name: UTF8 string name.
    /// - Throws: ``FullTrackNameError/parseError`` if strings are not UTF8.
    init(namespace: String, name: String) throws {
        guard let namespace = namespace.data(using: .utf8) else {
            throw FullTrackNameError.parseError
        }
        self.nameSpace = [namespace]
        guard let name = name.data(using: .utf8) else {
            throw FullTrackNameError.parseError
        }
        self.name = name
    }

    init(_ ftn: QFullTrackName) {
        self.nameSpace = ftn.nameSpace
        self.name = ftn.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.name)
        hasher.combine(self.nameSpace)
    }

    /// Get the namespace as an UTF8 string.
    /// - Returns: UTF8 string of namespace.
    /// - Throws: ``FullTrackNameError/parseError`` if ``namespace`` is not ecodable as UTF8.
    func getNamespace() throws -> String {
        guard let element = self.nameSpace.first,
              let namespace = String(data: element, encoding: .utf8) else {
            throw FullTrackNameError.parseError
        }
        return namespace
    }

    /// Get the name as an UTF8 string.
    /// - Returns: UTF8 string of name.
    /// - Throws: ``FullTrackNameError/parseError`` if ``name`` is not ecodable as UTF8.
    func getName() throws -> String {
        guard let name = String(data: self.name, encoding: .utf8) else {
            throw FullTrackNameError.parseError
        }
        return name
    }
}
