// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
@testable import QuicR

final class TestVideoSubscription: XCTestCase {
    func testMetrics() throws {
        let subscription = try VideoSubscription(fullTrackName: try .init(namespace: [""], name: ""),
                                                 config: .init(codec: .h264,
                                                               bitrate: 0,
                                                               fps: 30,
                                                               width: 1920,
                                                               height: 1080,
                                                               bitrateType: .average),
                                                 participants: .init(),
                                                 metricsSubmitter: nil,
                                                 videoBehaviour: .freeze,
                                                 reliable: true,
                                                 granularMetrics: true,
                                                 jitterBufferConfig: .init(),
                                                 simulreceive: .none,
                                                 variances: .init(expectedOccurrences: 0),
                                                 endpointId: "",
                                                 relayId: "") { _, _ in }
        subscription.metricsSampled(.init())
    }
}
