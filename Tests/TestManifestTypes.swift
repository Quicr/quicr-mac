// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
@testable import QuicR

final class TestManifestTypes: XCTestCase {
    func testGetPrioritySuccess() throws {
        let profile = Profile(
            qualityProfile: "test",
            expiry: nil,
            priorities: [0, 128, 255],
            namespace: ["test"]
        )

        XCTAssertEqual(try profile.getPriority(index: 0), 0)
        XCTAssertEqual(try profile.getPriority(index: 1), 128)
        XCTAssertEqual(try profile.getPriority(index: 2), 255)
    }

    func testGetPriorityMissingPriorities() {
        let profile = Profile(
            qualityProfile: "test",
            expiry: nil,
            priorities: nil,
            namespace: ["test"]
        )

        XCTAssertThrowsError(try profile.getPriority(index: 0)) { error in
            guard case Profile.ProfileError.missingEntry(let index) = error else {
                XCTFail("Expected missingEntry error")
                return
            }
            XCTAssertEqual(index, 0)
        }
    }

    func testGetPriorityNegativeValue() {
        let profile = Profile(
            qualityProfile: "test",
            expiry: nil,
            priorities: [-1],
            namespace: ["test"]
        )

        XCTAssertThrowsError(try profile.getPriority(index: 0)) { error in
            guard case Profile.ProfileError.invalidValue(let index, let value) = error else {
                XCTFail("Expected invalidValue error")
                return
            }
            XCTAssertEqual(index, 0)
            XCTAssertEqual(value, -1)
        }
    }

    func testGetPriorityOverflow() {
        let profile = Profile(
            qualityProfile: "test",
            expiry: nil,
            priorities: [256],
            namespace: ["test"]
        )

        XCTAssertThrowsError(try profile.getPriority(index: 0)) { error in
            guard case Profile.ProfileError.invalidValue(let index, let value) = error else {
                XCTFail("Expected invalidValue error")
                return
            }
            XCTAssertEqual(index, 0)
            XCTAssertEqual(value, 256)
        }
    }

    func testGetTTLSuccess() throws {
        let profile = Profile(
            qualityProfile: "test",
            expiry: [0, 1000, 65535],
            priorities: nil,
            namespace: ["test"]
        )

        XCTAssertEqual(try profile.getTTL(index: 0), 0)
        XCTAssertEqual(try profile.getTTL(index: 1), 1000)
        XCTAssertEqual(try profile.getTTL(index: 2), 65535)
    }

    func testGetTTLMissingExpiry() {
        let profile = Profile(
            qualityProfile: "test",
            expiry: nil,
            priorities: nil,
            namespace: ["test"]
        )

        XCTAssertThrowsError(try profile.getTTL(index: 0)) { error in
            guard case Profile.ProfileError.missingEntry(let index) = error else {
                XCTFail("Expected missingEntry error")
                return
            }
            XCTAssertEqual(index, 0)
        }
    }

    func testGetTTLNegativeValue() {
        let profile = Profile(
            qualityProfile: "test",
            expiry: [-1],
            priorities: nil,
            namespace: ["test"]
        )

        XCTAssertThrowsError(try profile.getTTL(index: 0)) { error in
            guard case Profile.ProfileError.invalidValue(let index, let value) = error else {
                XCTFail("Expected invalidValue error")
                return
            }
            XCTAssertEqual(index, 0)
            XCTAssertEqual(value, -1)
        }
    }

    func testGetTTLOverflow() {
        let profile = Profile(
            qualityProfile: "test",
            expiry: [65536],
            priorities: nil,
            namespace: ["test"]
        )

        XCTAssertThrowsError(try profile.getTTL(index: 0)) { error in
            guard case Profile.ProfileError.invalidValue(let index, let value) = error else {
                XCTFail("Expected invalidValue error")
                return
            }
            XCTAssertEqual(index, 0)
            XCTAssertEqual(value, 65536)
        }
    }
}
