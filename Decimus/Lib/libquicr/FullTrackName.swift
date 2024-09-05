// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Possible errors raised by ``FullTrackName``.
enum FullTrackNameError: Error {
    /// A ``FullTrackName`` could not constructed or parsed into a `String`.
    case parseError
}

/// A MoQ full track name identifies a track within a namespace.
struct FullTrackName: Hashable {
    /// The namespace portion of the full track name.
    let namespace: Data
    /// The name portion of the full track name.
    let name: Data

    /// Construct a full track name from ASCII string components.
    /// - Parameter namespace: ASCII string namespace.
    /// - Parameter name: ASCII string name.
    /// - Throws: ``FullTrackNameError/parseError`` if strings are not ASCII.
    init(namespace: String, name: String) throws {
        guard let namespace = namespace.data(using: .ascii) else {
            throw FullTrackNameError.parseError
        }
        self.namespace = namespace
        guard let name = name.data(using: .ascii) else {
            throw FullTrackNameError.parseError
        }
        self.name = name
    }

    /// Get the namespace as an ASCII string.
    /// - Returns: ASCII string of namespace.
    /// - Throws: ``FullTrackNameError/parseError`` if ``namespace`` is not ecodable as ASCII.
    func getNamespace() throws -> String {
        guard let namespace = String(data: self.namespace, encoding: .ascii) else {
            throw FullTrackNameError.parseError
        }
        return namespace
    }

    /// Get the name as an ASCII string.
    /// - Returns: ASCII string of name.
    /// - Throws: ``FullTrackNameError/parseError`` if ``name`` is not ecodable as ASCII.
    func getName() throws -> String {
        guard let name = String(data: self.name, encoding: .ascii) else {
            throw FullTrackNameError.parseError
        }
        return name
    }

    /// Get the underlying ``QFullTrackName`` object corresponding to this ``FullTrackName``.
    /// This reference MUST NOT be used outside of the scope of the owning ``FullTrackName``.
    /// - Returns: A ``QFullTrackName`` view into this ``FullTrackName``.
    func getUnsafe() -> QFullTrackName {
        return self.namespace.withUnsafeBytes { namespace in
            let namespacePtr: UnsafePointer<CChar> = namespace.baseAddress!.bindMemory(to: CChar.self,
                                                                                       capacity: namespace.count)
            return self.name.withUnsafeBytes { name in
                let namePtr: UnsafePointer<CChar> = name.baseAddress!.bindMemory(to: CChar.self, capacity: name.count)

                return .init(nameSpace: namespacePtr,
                             nameSpaceLength: self.namespace.count,
                             name: namePtr,
                             nameLength: self.name.count)
            }
        }
    }
}
