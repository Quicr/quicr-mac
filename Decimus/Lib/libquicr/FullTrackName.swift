// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Possible errors raised by ``FullTrackName``.
enum FullTrackNameError: Error {
    /// A ``FullTrackName`` could not constructed or parsed into a `String`.
    case parseError
    /// The serialized name contained invalid encoding (e.g. uppercase hex, redundant encoding).
    case invalidEncoding
}

// MARK: - MoQ Name Encoding (RFC Section 1.5)

/// Encode a single binary tuple to the MoQ safe string format.
/// Safe bytes (a-z, A-Z, 0-9, _) are output literally; all others as `.XX` lowercase hex.
func moqEncodeTuple(_ data: Data) -> String {
    var result = ""
    result.reserveCapacity(data.count)
    for byte in data {
        switch byte {
        case 0x61...0x7A, // a-z
             0x41...0x5A, // A-Z
             0x30...0x39, // 0-9
             0x5F:        // _
            result.append(Character(UnicodeScalar(byte)))
        default:
            result.append(String(format: ".%02x", byte))
        }
    }
    return result
}

/// Decode a MoQ-encoded tuple string back to binary data.
/// Enforces canonical encoding: lowercase hex only, no redundant escapes.
func moqDecodeTuple(_ string: Substring) throws -> Data {
    var data = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let char = string[index]
        if char == "." {
            // Must be followed by exactly two hex digits.
            let hexStart = string.index(after: index)
            guard hexStart < string.endIndex else { throw FullTrackNameError.invalidEncoding }
            let hexEnd = string.index(after: hexStart)
            guard hexEnd < string.endIndex else { throw FullTrackNameError.invalidEncoding }
            let hex = string[hexStart...hexEnd]

            // Must be lowercase hex.
            guard hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
                throw FullTrackNameError.invalidEncoding
            }
            guard let byte = UInt8(hex, radix: 16) else { throw FullTrackNameError.invalidEncoding }

            // Reject redundant encoding of literal-safe bytes.
            switch byte {
            case 0x61...0x7A, 0x41...0x5A, 0x30...0x39, 0x5F:
                throw FullTrackNameError.invalidEncoding
            default:
                break
            }

            data.append(byte)
            index = string.index(after: hexEnd)
        } else {
            guard let scalar = char.asciiValue else { throw FullTrackNameError.invalidEncoding }
            // Only literal-safe bytes allowed unescaped.
            switch scalar {
            case 0x61...0x7A, 0x41...0x5A, 0x30...0x39, 0x5F:
                data.append(scalar)
            default:
                throw FullTrackNameError.invalidEncoding
            }
            index = string.index(after: index)
        }
    }
    return data
}

/// A MoQ full track name identifies a track within a namespace.
class FullTrackName: QFullTrackName, Hashable, CustomStringConvertible {
    /// Serialized representation per MoQ encoding (RFC Section 1.5).
    var description: String {
        let nsPart = nameSpace.map { moqEncodeTuple($0) }.joined(separator: "-")
        let namePart = moqEncodeTuple(name)
        return "\(nsPart)--\(namePart)"
    }

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
    }

    init(_ ftn: QFullTrackName) {
        self.nameSpace = ftn.nameSpace
        self.name = ftn.name
    }

    /// Parse a serialized MoQ name string (RFC Section 1.5) back into a FullTrackName.
    /// - Throws: ``FullTrackNameError/invalidEncoding`` on malformed input.
    init(serialized: String) throws {
        // Split on "--" to separate namespace from track name.
        guard let separatorRange = serialized.range(of: "--") else {
            throw FullTrackNameError.invalidEncoding
        }
        let nsPart = serialized[serialized.startIndex..<separatorRange.lowerBound]
        let namePart = serialized[separatorRange.upperBound...]

        // Namespace tuples are separated by single "-".
        // We need to split on "-" but not "--" (already consumed).
        let tuples = nsPart.split(separator: "-", omittingEmptySubsequences: false)
        guard !tuples.isEmpty else { throw FullTrackNameError.invalidEncoding }

        self.nameSpace = try tuples.map { try moqDecodeTuple($0) }
        self.name = try moqDecodeTuple(namePart)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.name)
        hasher.combine(self.nameSpace)
    }

    func matchesPrefix(_ prefix: NamespacePrefix) -> Bool {
        self.nameSpace.starts(with: prefix.elements)
    }
}

extension Profile {
    func getFullTrackName() throws -> FullTrackName {
        try .init(namespace: self.namespace, name: self.name ?? "")
    }
}
