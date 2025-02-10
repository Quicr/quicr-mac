// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Testing
@testable import QuicR

extension VideoSubscription {
    func mockObject(groupId: UInt64, objectId: UInt64) {
        let priority: UInt8 = 0
        let ttl: UInt16 = 0
        withUnsafePointer(to: priority) { priorityPtr in
            withUnsafePointer(to: ttl) { ttlPtr in
                self.objectReceived(.init(groupId: groupId,
                                          objectId: objectId,
                                          payloadLength: 0,
                                          priority: priorityPtr,
                                          ttl: ttlPtr),
                                    data: .init(),
                                    extensions: nil)
            }
        }
    }
}

struct TestVideoSubscription {
    @MainActor
    private func makeSubscription(_ mockClient: MockClient) async throws -> VideoSubscription {
        let controller = MoqCallController(endpointUri: "",
                                           client: mockClient,
                                           submitter: nil,
                                           callEnded: ({}))
        try await controller.connect()
        return try VideoSubscription(profile: .init(qualityProfile: "h264,width=1920,height=1080,fps=30,br=2000",
                                                    expiry: [1],
                                                    priorities: [1],
                                                    namespace: ["0"]),
                                     config: .init(codec: .h264,
                                                   bitrate: 2000,
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
                                     relayId: "",
                                     participantId: .init(1),
                                     joinDate: .now,
                                     controller: controller,
                                     verbose: true,
                                     callback: ({ _, _ in }),
                                     statusChanged: ({_ in }))
    }

    @Test("Metrics")
    @MainActor
    func testMetrics() async throws {
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: {_ in},
                                    fetchCancel: {_ in})
        let subscription = try await self.makeSubscription(mockClient)
        subscription.metricsSampled(.init())
    }

    @Test("No Fetch")
    @MainActor
    func testNoFetch() async throws {
        // We want to validate that when we get the start of the group, no fetch is started.
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: {_ in #expect(Bool(false)) },
                                    fetchCancel: {_ in #expect(Bool(false)) })
        let subscription = try await self.makeSubscription(mockClient)
        subscription.mockObject(groupId: 0, objectId: 0)
    }

    @Test("Test Fetch")
    @MainActor
    func testFetch() async throws {
        // We want to validate a fetch operation is kicked off when the first object is >0.
        var fetch: Fetch?
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { fetch = $0 },
                                    fetchCancel: { _ in #expect(Bool(false)) })
        let subscription = try await self.makeSubscription(mockClient)
        subscription.mockObject(groupId: 0, objectId: 2)
        #expect(fetch != nil)
        #expect(fetch!.getStartGroup() == 0)
        #expect(fetch!.getEndGroup() == 0)
        #expect(fetch!.getStartObject() == 0)
        #expect(fetch!.getEndObject() == 2)
    }
}
