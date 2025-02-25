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
    private func makeSubscription(_ mockClient: MockClient,
                                  fetchThreshold: UInt64,
                                  ngThreshold: UInt64) async throws -> VideoSubscription {
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
                                     cleanupTime: 1.5,
                                     subscriptionConfig: .init(joinConfig: .init(fetchUpperThreshold: fetchThreshold,
                                                                                 newGroupUpperThreshold: ngThreshold)),
                                     callback: ({ _, _, _ in }),
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
        let subscription = try await self.makeSubscription(mockClient, fetchThreshold: 0, ngThreshold: 0)
        subscription.metricsSampled(.init())
    }

    private static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    let fetchThreshold: UInt64 = 10
    let ngThreshold: UInt64 = 100

    @Test("First object was start of group", .enabled(if: Self.isDebug))
    @MainActor
    func testNoFetch() async throws {
        // When we get the start of the group:
        // - No fetch is kicked off.
        // - No new group is requested.
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: {_ in #expect(Bool(false)) },
                                    fetchCancel: {_ in #expect(Bool(false)) })
        var newGroup = false
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold)
        #if DEBUG
        subscription.setNewGroupCallback({ usrData in
            let bool = usrData.assumingMemoryBound(to: Bool.self)
            bool.pointee = true
        }, context: &newGroup)
        #endif
        subscription.mockObject(groupId: 0, objectId: 0)
        #expect(newGroup == false)
    }

    @Test("Test early in group", .enabled(if: Self.isDebug))
    @MainActor
    func testFetch() async throws {
        // When we get an object early in the group.
        // - FETCH for missing data.
        // - No new group.
        var fetch: Fetch?
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { fetch = $0 },
                                    fetchCancel: { _ in #expect(Bool(false)) })
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold)
        var newGroup = false
        #if DEBUG
        subscription.setNewGroupCallback({ usrData in
            let bool = usrData.assumingMemoryBound(to: Bool.self)
            bool.pointee = true
        }, context: &newGroup)
        #endif
        let arrivedGroup: UInt64 = 0
        let arrivedObject: UInt64 = fetchThreshold - 1

        subscription.mockObject(groupId: arrivedGroup, objectId: arrivedObject)
        #expect(fetch != nil)
        #expect(fetch!.getStartGroup() == arrivedGroup)
        #expect(fetch!.getEndGroup() == arrivedGroup + 1)
        #expect(fetch!.getStartObject() == 0)
        #expect(fetch!.getEndObject() == arrivedObject)
        #expect(newGroup == false)
    }

    @Test("Test middle of group", .enabled(if: Self.isDebug))
    @MainActor
    func testNewGroup() async throws {
        // We want to validate that a new group instead of fetch is kicked off,
        // when we're >10 objects in.
        var fetch: Fetch?
        var newGroup = false
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { fetch = $0 },
                                    fetchCancel: { _ in #expect(Bool(false)) })
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold)
        #if DEBUG
        subscription.setNewGroupCallback({ usrData in
            let bool = usrData.assumingMemoryBound(to: Bool.self)
            bool.pointee = true
        }, context: &newGroup)
        #endif
        subscription.mockObject(groupId: 0, objectId: fetchThreshold)
        #expect(fetch == nil)
        #expect(newGroup == true)
    }

    @Test("Test Wait Too Late For New Group", .enabled(if: Self.isDebug))
    @MainActor
    func testLateNewGroup() async throws {
        // We want to validate that no new group or fetch is kicked off,
        // when we're >100 objects in.
        var fetch: Fetch?
        var newGroup = false
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { fetch = $0 },
                                    fetchCancel: { _ in #expect(Bool(false)) })
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold)
        #if DEBUG
        subscription.setNewGroupCallback({ usrData in
            let bool = usrData.assumingMemoryBound(to: Bool.self)
            bool.pointee = true
        }, context: &newGroup)
        #endif
        subscription.mockObject(groupId: 0, objectId: ngThreshold)
        #expect(fetch == nil)
        #expect(newGroup == false)
    }
}
