// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Possible errors thrown by ``TokenStorage``
enum TokenStorageError: Error {
    /// Token couldn't be (de)serialized to UTF8 bytes.
    case badToken
}

/// Easy storage of tokens to keychain by unique tag.
class TokenStorage {
    private let tag: String
    private let search: [CFString: Any]

    /// Create a new storage API for the given tag.
    /// - Parameter tag: Identifier for this entry.
    init(tag: String) throws {
        self.tag = tag
        self.search = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: self.tag
        ]
    }

    /// Store a new string into the store.
    /// - Parameter token: Non empty UTF-8 encodable string.
    func store(_ token: String) throws {
        guard !token.isEmpty,
              let token = token.data(using: .utf8) else {
            throw TokenStorageError.badToken
        }

        let exists = try self.retrieve() != nil
        guard exists else {
            // Add.
            var query = self.search
            query[kSecValueData] = token
            try OSStatusError.checked("Add to keychain") {
                SecItemAdd(query as CFDictionary, nil)
            }
            return
        }

        // Update.
        let update: [String: Any] = [
            kSecValueData as String: token
        ]
        try OSStatusError.checked("Update keychain") {
            SecItemUpdate(self.search as CFDictionary, update as CFDictionary)
        }
    }

    /// Retrieve a previously stored token.
    /// - Returns: Stored token or nil if none stored.
    func retrieve() throws -> String? {
        var query = self.search
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var item: CFTypeRef?
        let found = SecItemCopyMatching(query as CFDictionary, &item)
        switch found {
        case errSecSuccess:
            let item = item! as! CFData
            let string = CFStringCreateFromExternalRepresentation(kCFAllocatorDefault,
                                                                  item,
                                                                  kCFStringEncodingASCII)
            guard let string = string else {
                throw TokenStorageError.badToken
            }
            return string as String
        case errSecItemNotFound:
            return nil
        default:
            throw OSStatusError(error: found, message: "Keychain retreive")
        }
    }

    /// Delete an existing entry.
    /// This will silently succeed if there is nothing to delete.
    func delete() throws {
        let delete = SecItemDelete(self.search as CFDictionary)
        switch delete {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw OSStatusError(error: delete, message: "Keychain delete")
        }
    }
}
