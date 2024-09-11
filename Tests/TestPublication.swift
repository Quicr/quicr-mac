// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import XCTest

final class TestPublication: XCTestCase {
    func testManifestExtractDefault() throws {
        let expectedPriority: UInt8 = 1
        let expectedTTL: UInt16 = 2
        let profile = Profile(qualityProfile: "", expiry: nil, priorities: nil, namespace: "namespace")
        let publication = try Publication(profile: profile,
                                          trackMode: .datagram,
                                          defaultPriority: expectedPriority,
                                          defaultTTL: expectedTTL)
        XCTAssertEqual(expectedPriority, publication.getPriority(.random(in: 0..<Int.max)))
        XCTAssertEqual(expectedTTL, publication.getTTL(.random(in: 0..<Int.max)))
    }

    func testManifestExtractIndexPresent() throws {
        let expectedPriority: UInt8 = 1
        let expectedTTL: UInt16 = 2
        let profile = Profile(qualityProfile: "", expiry: [3, 4], priorities: [5, 6], namespace: "namespace")
        let publication = try Publication(profile: profile,
                                          trackMode: .datagram,
                                          defaultPriority: expectedPriority,
                                          defaultTTL: expectedTTL)
        XCTAssertEqual(5, publication.getPriority(0))
        XCTAssertEqual(6, publication.getPriority(1))
        XCTAssertEqual(expectedPriority, publication.getPriority(3))
        XCTAssertEqual(3, publication.getTTL(0))
        XCTAssertEqual(4, publication.getTTL(1))
        XCTAssertEqual(expectedTTL, publication.getTTL(3))
    }
}
