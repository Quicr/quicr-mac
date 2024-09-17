// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
@testable import QuicR

final class TestManifestController: XCTestCase {
    func testServerConfig() throws {
        let controller = ManifestController()
        guard let example = URL(string: "http://example.org") else { XCTFail(); return }
        try controller.setServer(config: .init(url: example, config: ""))
    }
}
