// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Testing
@testable import QuicR

extension VideoSubscription {
    func mockObject(groupId: UInt64,
                    objectId: UInt64,
                    extensions: HeaderExtensions? = nil,
                    immutableExtensions: HeaderExtensions? = nil) {
        let priority: UInt8 = 0
        let ttl: UInt16 = 0
        withUnsafePointer(to: priority) { priorityPtr in
            withUnsafePointer(to: ttl) { ttlPtr in
                self.objectReceived(.init(groupId: groupId,
                                          objectId: objectId,
                                          payloadLength: 0,
                                          priority: priorityPtr,
                                          ttl: ttlPtr),
                                    data: Data([0x01]),
                                    extensions: extensions,
                                    immutableExtensions: immutableExtensions)
            }
        }
    }
}

struct TestVideoSubscription {
    @MainActor
    private func makeSubscription(_ mockClient: MockClient,
                                  fetchThreshold: UInt64,
                                  ngThreshold: UInt64,
                                  callback: ObjectReceivedCallback? = nil) async throws -> VideoSubscription {
        let controller = MoqCallController(endpointUri: "",
                                           client: mockClient,
                                           submitter: nil,
                                           callEnded: ({}))
        try await controller.connect()
        return try VideoSubscription(profile: .init(qualityProfile: "h264,width=1920,height=1080,fps=30,br=2000",
                                                    expiry: [1],
                                                    priorities: [1],
                                                    namespace: ["0"]),
                                     config: .init(codec: .mock,
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
                                     activeSpeakerStats: nil,
                                     controller: controller,
                                     verbose: true,
                                     cleanupTime: 1.5,
                                     subscriptionConfig: .init(joinConfig: .init(fetchUpperThreshold: fetchThreshold,
                                                                                 newGroupUpperThreshold: ngThreshold),
                                                               calculateLatency: false,
                                                               mediaInterop: false),
                                     sframeContext: nil,
                                     wifiScanDetector: nil,
                                     callback: { callback?($0) },
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

    let fetchThreshold: UInt64 = 10
    let ngThreshold: UInt64 = 100

    @Test("First object was start of group")
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
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold)
        subscription.mockObject(groupId: 0, objectId: 0)
        #expect(subscription.getCurrentState() == .running)
    }

    @Test("Test early in group")
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
        let arrivedGroup: UInt64 = 0
        let arrivedObject: UInt64 = fetchThreshold - 1

        subscription.mockObject(groupId: arrivedGroup, objectId: arrivedObject)

        switch subscription.getCurrentState() {
        case .fetching(let fetching):
            #expect(fetching.getStartGroup() == arrivedGroup)
            #expect(fetching.getEndGroup() == arrivedGroup)
            #expect(fetching.getStartObject() == 0)
            #expect(fetching.getEndObject() == arrivedObject)
            #expect(fetch == fetching)
        default:
            #expect(Bool(false), "Expected fetching state, got \(subscription.getCurrentState())")
        }
        #expect(fetch != nil)
    }

    @Test("Test middle of group")
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
        subscription.mockObject(groupId: 0, objectId: fetchThreshold)
        switch subscription.getCurrentState() {
        case .waitingForNewGroup(let requested):
            newGroup = requested
        default:
            break
        }
        #expect(fetch == nil)
        #expect(newGroup)
    }

    @Test("Test Wait Too Late For New Group")
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
        subscription.mockObject(groupId: 0, objectId: ngThreshold)
        switch subscription.getCurrentState() {
        case .waitingForNewGroup(let requested):
            newGroup = requested
        default:
            break
        }
        #expect(fetch == nil)
        #expect(newGroup == false)
    }

    @Test("Test New Group State")
    @MainActor
    func testNewGroupResult() async throws {
        var gotGroupId: UInt64?
        var gotObjectId: UInt64?
        var shouldDrop: Bool?
        let callback: ObjectReceivedCallback = { details in
            shouldDrop = !details.usable
            gotGroupId = details.headers.groupId
            gotObjectId = details.headers.objectId
        }

        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { _ in },
                                    fetchCancel: { _ in  })
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold,
                                                           callback: callback)

        var sentGroupId: UInt64 = 0
        var sendObjectId = ngThreshold

        var sequence: UInt64 = 0
        func loc() -> [NSNumber: Data] {
            sequence += 1
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(sequence))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        // Get into waiting for new group state.
        subscription.mockObject(groupId: sentGroupId, objectId: sendObjectId, extensions: loc())
        #expect(shouldDrop == true)
        #expect(gotGroupId == sentGroupId)
        #expect(gotObjectId == sendObjectId)

        // We want to validate that when we're waiting for a new group,
        // we drop middle of group objects.
        sendObjectId += 1
        subscription.mockObject(groupId: sentGroupId, objectId: sendObjectId, extensions: loc())
        #expect(shouldDrop == true)
        #expect(gotGroupId == sentGroupId)
        #expect(gotObjectId == sendObjectId)

        // When a new group does arrive, we use it.
        sentGroupId += 1
        sendObjectId = 0
        subscription.mockObject(groupId: sentGroupId, objectId: sendObjectId, extensions: loc())
        #expect(shouldDrop == false)
        #expect(gotGroupId == sentGroupId)
        #expect(gotObjectId == sendObjectId)
    }
}
