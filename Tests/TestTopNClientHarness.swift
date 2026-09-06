// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest

@MainActor
final class TestTopNClientHarness: XCTestCase {
    func testTopNClientFlow() async throws {
        let environment = ProcessInfo.processInfo.environment
        let bundle = Bundle(for: Self.self)
        let fixturePreflight = environment["TOPN_HARNESS_FIXTURE_PREFLIGHT"]
            ?? bundle.object(forInfoDictionaryKey: "TOPN_HARNESS_FIXTURE_PREFLIGHT") as? String
        if fixturePreflight == "1" {
            let fixture = try TopNH264Fixture.loadFromTestBundle()
            try await TopNHarnessPreflight.validateFixture(fixture)
            return
        }
        let configPath = environment["TOPN_HARNESS_CONFIG"]
            ?? bundle.object(forInfoDictionaryKey: "TOPN_HARNESS_CONFIG") as? String
        guard let path = configPath, !path.isEmpty, !path.hasPrefix("$(") else {
            throw XCTSkip("Set TOPN_HARNESS_CONFIG via tools/run_topn_client_harness.py")
        }
        let configuration = try TopNHarnessConfiguration.load(path: path)
        try await TopNHarnessCoordinator(configuration: configuration).run()
    }
}
