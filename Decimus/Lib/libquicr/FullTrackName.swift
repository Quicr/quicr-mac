// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Possible errors raised by ``FullTrackName``.
enum FullTrackNameError: Error {
    /// A ``FullTrackName`` could not constructed or parsed into a `String`.
    case parseError
}

/// A MoQ full track name identifies a track within a namespace.
class FullTrackName: QFullTrackName, Hashable, CustomStringConvertible {
    var description: String {
        self.nameSpace.compactMap { String(data: $0, encoding: .utf8) }.joined()
    }

    static func == (lhs: FullTrackName, rhs: FullTrackName) -> Bool {
        lhs.nameSpace == rhs.nameSpace && lhs.name == rhs.name
    }

    /// The namespace portion of the full track name.
    let nameSpace: [Data]
    /// The name portion of the full track name.
    let name: Data
    
    let trackNamespace: [String] = []
    let trackName : String = ""
    

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
}

extension Profile {
    func getFullTrackName() throws -> FullTrackName {
        try .init(namespace: self.trackNamespace, name: self.trackName)
    }
}
