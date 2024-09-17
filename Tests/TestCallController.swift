// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
@testable import QuicR

final class TestCallController: XCTestCase {
    func testMetrics() throws {
        let config = ClientConfig(connectUri: "moq://localhost",
                                  endpointUri: "me",
                                  transportConfig: .init(),
                                  metricsSampleMs: 0)
        let controller = MoqCallController(config: config,
                                           captureManager: try .init(metricsSubmitter: nil,
                                                                     granularMetrics: false),
                                           subscriptionConfig: .init(),
                                           engine: try .init(),
                                           videoParticipants: .init(),
                                           submitter: nil,
                                           granularMetrics: false,
                                           callEnded: {})
        controller.metricsSampled(.init())
    }
}
