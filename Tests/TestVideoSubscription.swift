// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
@testable import QuicR

final class TestVideoSubscription: XCTestCase {
    @MainActor
    func testMetrics() async throws {
        let subscription = try VideoSubscription(profile: .init(qualityProfile: "h264,width=1920,height=1080,fps=30,br=2000",
                                                                expiry: [1],
                                                                priorities: [1],
                                                                namespace: ["0"]),
                                                 config: .init(codec: .h264, bitrate: 2000, fps: 30, width: 1920, height: 1080, bitrateType: .average),
                                                 participants: .init(nil),
                                                 metricsSubmitter: nil,
                                                 videoBehaviour: .freeze,
                                                 reliable: true,
                                                 granularMetrics: true,
                                                 jitterBufferConfig: .init(),
                                                 simulreceive: .none,
                                                 variances: .init(expectedOccurrences: 0),
                                                 endpointId: "",
                                                 relayId: "",
                                                 participantId: .init(1),
                                                 joinDate: .now,
                                                 callback: ({ _, _ in }),
                                                 statusChanged: ({_ in }))
        subscription.metricsSampled(.init())
    }
}
