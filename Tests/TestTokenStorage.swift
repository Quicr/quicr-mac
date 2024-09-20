// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
@testable import QuicR

final class TestTokenStorage: XCTestCase {
    func testStoreAndRetrieve() throws {
        let storage = try TokenStorage(tag: "foo")
        addTeardownBlock {
            try storage.delete()
        }
        // Add.
        try storage.store("bar")
        // Update.
        try storage.store("baz")
        // Fetch.
        let result = try storage.retrieve()
        XCTAssertEqual(result, "baz")
        // Delete.
        try storage.delete()
        // Fetch nil.
        XCTAssertNil(try storage.retrieve())
    }
}
