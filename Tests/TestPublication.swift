// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import XCTest

final class TestPublication: XCTestCase {
    func testManifestExtractDefault() throws {
        let expectedPriority: UInt8 = 1
        let expectedTTL: UInt16 = 2
        let profile = Profile(qualityProfile: "", expiry: nil, priorities: nil, namespace: ["namespace"])
        let defaults = PublicationDefaults(profile: profile,
                                           defaultPriority: expectedPriority,
                                           defaultTTL: expectedTTL)
        XCTAssertEqual(expectedPriority, defaults.priority(at: .random(in: 0..<Int.max)))
        XCTAssertEqual(expectedTTL, defaults.ttl(at: .random(in: 0..<Int.max)))
    }

    func testManifestExtractIndexPresent() throws {
        let expectedPriority: UInt8 = 1
        let expectedTTL: UInt16 = 2
        let profile = Profile(qualityProfile: "", expiry: [3, 4], priorities: [5, 6], namespace: ["namespace"])
        let defaults = PublicationDefaults(profile: profile,
                                           defaultPriority: expectedPriority,
                                           defaultTTL: expectedTTL)
        XCTAssertEqual(5, defaults.priority(at: 0))
        XCTAssertEqual(6, defaults.priority(at: 1))
        XCTAssertEqual(expectedPriority, defaults.priority(at: 3))
        XCTAssertEqual(3, defaults.ttl(at: 0))
        XCTAssertEqual(4, defaults.ttl(at: 1))
        XCTAssertEqual(expectedTTL, defaults.ttl(at: 3))
    }
}
