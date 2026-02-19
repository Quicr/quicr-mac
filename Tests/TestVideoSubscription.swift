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
                                          subgroupId: 0,
                                          objectId: objectId,
                                          payloadLength: 0,
                                          status: .available,
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
                                     publisherInitiated: false,
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
            let startLocation = fetching.getStartLocation()
            let endLocation = fetching.getEndLocation()
            #expect(startLocation.group == arrivedGroup)
            #expect(startLocation.object == 0)
            #expect(endLocation.group == arrivedGroup)
            #expect(endLocation.object?.uint64Value == arrivedObject - 1)
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
        func loc() -> HeaderExtensions {
            sequence += 1
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(sequence))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        // Get into waiting for new group state.
        subscription.mockObject(groupId: sentGroupId, objectId: sendObjectId, extensions: nil, immutableExtensions: loc())
        #expect(shouldDrop == true)
        #expect(gotGroupId == sentGroupId)
        #expect(gotObjectId == sendObjectId)

        // We want to validate that when we're waiting for a new group,
        // we drop middle of group objects.
        sendObjectId += 1
        subscription.mockObject(groupId: sentGroupId, objectId: sendObjectId, extensions: nil, immutableExtensions: loc())
        #expect(shouldDrop == true)
        #expect(gotGroupId == sentGroupId)
        #expect(gotObjectId == sendObjectId)

        // When a new group does arrive, we use it.
        sentGroupId += 1
        sendObjectId = 0
        subscription.mockObject(groupId: sentGroupId, objectId: sendObjectId, extensions: nil, immutableExtensions: loc())
        #expect(shouldDrop == false)
        #expect(gotGroupId == sentGroupId)
        #expect(gotObjectId == sendObjectId)
    }

    @Test("Pause from running state")
    @MainActor
    func testPauseFromRunning() async throws {
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: {_ in},
                                    fetchCancel: {_ in})
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold)
        func loc() -> HeaderExtensions {
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(0))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        // Get to running state
        subscription.mockObject(groupId: 0, objectId: 0, extensions: nil, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)

        // Pause
        subscription.pause()
        #expect(subscription.getCurrentState() == .startup)
    }

    @Test("Pause from fetching state cancels fetch")
    @MainActor
    func testPauseFromFetching() async throws {
        var fetchCancelled = false
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: {_ in},
                                    fetchCancel: {_ in fetchCancelled = true})
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold)

        func loc() -> HeaderExtensions {
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(0))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        // Get to fetching state
        subscription.mockObject(groupId: 0, objectId: fetchThreshold - 1, extensions: nil, immutableExtensions: loc())
        #expect(subscription.getCurrentState() != .running)

        // Pause should cancel fetch
        subscription.pause()
        #expect(subscription.getCurrentState() == .startup)
        #expect(fetchCancelled == true)
    }

    @Test("Pause from waitingForNewGroup state")
    @MainActor
    func testPauseFromWaitingForNewGroup() async throws {
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: {_ in},
                                    fetchCancel: {_ in})
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold)

        func loc() -> HeaderExtensions {
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(0))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        // Get to waitingForNewGroup state
        subscription.mockObject(groupId: 0, objectId: ngThreshold, extensions: nil, immutableExtensions: loc())
        switch subscription.getCurrentState() {
        case .waitingForNewGroup:
            break
        default:
            #expect(Bool(false), "Expected waitingForNewGroup state")
        }

        // Pause
        subscription.pause()
        #expect(subscription.getCurrentState() == .startup)
    }

    @Test("Objects dropped while paused")
    @MainActor
    func testObjectsDroppedWhilePaused() async throws {
        var callbackCount = 0
        let callback: ObjectReceivedCallback = { _ in
            callbackCount += 1
        }

        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: {_ in},
                                    fetchCancel: {_ in})
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold,
                                                           callback: callback)
        var sequence: UInt64 = 0
        func loc() -> HeaderExtensions {
            sequence += 1
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(sequence))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        // Get to running state
        subscription.mockObject(groupId: 0, objectId: 0, extensions: nil, immutableExtensions: loc())
        #expect(callbackCount == 1)

        // Pause
        subscription.pause()
        #expect(subscription.getCurrentState() == .startup)

        // Send more objects - should be dropped
        subscription.mockObject(groupId: 0, objectId: 1, extensions: nil, immutableExtensions: loc())
        subscription.mockObject(groupId: 0, objectId: 2, extensions: nil, immutableExtensions: loc())

        // Callback should not have been called for paused objects
        #expect(callbackCount == 1)
        #expect(subscription.getCurrentState() == .startup)
    }

    @Test("Resume after pause allows state transitions")
    @MainActor
    func testResumeAfterPause() async throws {
        var callbackCount = 0
        let callback: ObjectReceivedCallback = { _ in
            callbackCount += 1
        }

        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: {_ in},
                                    fetchCancel: {_ in})
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold,
                                                           callback: callback)

        var sequence: UInt64 = 0
        func loc() -> HeaderExtensions {
            sequence += 1
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(sequence))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        // Get to running state
        subscription.mockObject(groupId: 0, objectId: 0, extensions: nil, immutableExtensions: loc())
        #expect(callbackCount == 1)
        #expect(subscription.getCurrentState() == .running)

        // Pause
        subscription.pause()
        #expect(subscription.getCurrentState() == .startup)

        // Send object while paused - should be dropped
        subscription.mockObject(groupId: 0, objectId: 1, extensions: nil, immutableExtensions: loc())
        #expect(callbackCount == 1)

        // Resume
        subscription.resume()

        // Send new object - should be processed and transition to running
        subscription.mockObject(groupId: 1, objectId: 0, extensions: nil, immutableExtensions: loc())
        #expect(callbackCount == 2)
        #expect(subscription.getCurrentState() == .running)
    }

    @Test("Pause from startup state is valid")
    @MainActor
    func testPauseFromStartup() async throws {
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: {_ in},
                                    fetchCancel: {_ in})
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold)
        // Already in startup state
        #expect(subscription.getCurrentState() == .startup)

        // Pause should be valid (no-op for state, but sets paused flag)
        subscription.pause()
        #expect(subscription.getCurrentState() == .startup)

        // Objects should still be dropped
        func loc() -> HeaderExtensions {
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(0))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }
        subscription.mockObject(groupId: 0, objectId: 0, extensions: nil, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .startup)
    }

    @Test("Pause during fetch prevents fetch completion transition")
    @MainActor
    func testPauseDuringFetchPreventsCompletion() async throws {
        var fetch: Fetch?
        var fetchCancelled = false
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: { fetch = $0 },
                                    fetchCancel: {_ in fetchCancelled = true})
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold)

        var sequence: UInt64 = 0
        func loc() -> HeaderExtensions {
            sequence += 1
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(sequence))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        // Start fetch by arriving mid-group
        let arrivedGroup: UInt64 = 0
        let arrivedObject: UInt64 = fetchThreshold - 1
        subscription.mockObject(groupId: arrivedGroup,
                                objectId: arrivedObject,
                                extensions: nil,
                                immutableExtensions: loc())

        switch subscription.getCurrentState() {
        case .fetching:
            break
        default:
            #expect(Bool(false), "Expected fetching state")
        }

        // Pause (should cancel fetch and go to startup)
        subscription.pause()
        #expect(subscription.getCurrentState() == .startup)
        #expect(fetchCancelled == true)

        // Simulate fetch completion callback arriving after pause
        // This should be ignored due to paused check
        if let fetch = fetch as? CallbackFetch {
            // Simulate the last object of the fetch arriving
            fetch.objectReceived(.init(groupId: arrivedGroup,
                                       subgroupId: 0,
                                       objectId: arrivedObject - 1,
                                       payloadLength: 0,
                                       status: .available,
                                       priority: nil,
                                       ttl: nil),
                                 data: .init([0x01]),
                                 extensions: nil,
                                 immutableExtensions: loc())
        }

        // State should remain startup (not transition to running)
        #expect(subscription.getCurrentState() == .startup)
    }
}
