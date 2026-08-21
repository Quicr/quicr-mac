// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

// swiftlint:disable file_length type_body_length

import Dispatch
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
                                    immutableExtensions: immutableExtensions,
                                    streamHeaderProperties: nil)
            }
        }
    }
}

struct TestVideoSubscription {
    @MainActor
    func makeSubscription(_ mockClient: MockClient,
                          fetchThreshold: UInt64,
                          ngThreshold: UInt64,
                          callback: ObjectReceivedCallback? = nil,
                          jitterBufferConfig: JitterBuffer.Config = .init(),
                          cleanupTime: TimeInterval = 1.5,
                          participants: VideoParticipants? = nil,
                          activeSpeakerStats: ActiveSpeakerStats? = nil,
                          simulreceive: SimulreceiveMode = .none) async throws -> VideoSubscription {
        let participants = participants ?? .init()
        let controller = MoqCallController(endpointUri: "",
                                           client: mockClient,
                                           submitter: nil,
                                           callEnded: ({}))
        try await controller.connect()
        let subscription = try VideoSubscription(profile: .init(qualityProfile: "h264,width=1920,height=1080,fps=30,br=2000",
                                                                expiry: [1],
                                                                priorities: [1],
                                                                namespace: ["0"]),
                                                 config: .init(codec: .mock,
                                                               bitrate: 2000,
                                                               fps: 30,
                                                               width: 1920,
                                                               height: 1080,
                                                               bitrateType: .average),
                                                 participants: participants,
                                                 metricsSubmitter: nil,
                                                 videoBehaviour: .freeze,
                                                 granularMetrics: true,
                                                 jitterBufferConfig: jitterBufferConfig,
                                                 simulreceive: simulreceive,
                                                 variances: .init(expectedOccurrences: 0),
                                                 endpointId: "",
                                                 relayId: "",
                                                 participantId: .init(1),
                                                 joinDate: .now,
                                                 activeSpeakerStats: activeSpeakerStats,
                                                 controller: controller,
                                                 verbose: true,
                                                 cleanupTime: cleanupTime,
                                                 subscriptionConfig: .init(joinConfig: .init(fetchUpperThreshold: fetchThreshold,
                                                                                             newGroupUpperThreshold: ngThreshold),
                                                                           calculateLatency: false,
                                                                           mediaInterop: false,
                                                                           decodeQueueSize: 2),
                                                 sframeContext: nil,
                                                 wifiScanDetector: nil,
                                                 publisherInitiated: false,
                                                 callback: { callback?($0) },
                                                 statusChanged: ({_ in }))
        // Simulate the subscribe OK that would set this in production.
        subscription.supportNewGroupRequest(true)
        return subscription
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

    @Test("Cleanup removes the retained handler's participant")
    @MainActor
    func testCleanupRemovesRetainedHandlerParticipant() async throws {
        let participants = VideoParticipants()
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: {_ in},
                                    fetchCancel: {_ in})
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: 0,
                                                           ngThreshold: 0,
                                                           cleanupTime: 0.05,
                                                           participants: participants)
        let handler = subscription.handler.get()
        let retainedHandler = try #require(handler)
        for _ in 0..<100 where participants.participants.compactMap(\.value).isEmpty {
            await Task.yield()
        }
        try #require(!participants.participants.compactMap(\.value).isEmpty)

        subscription.mockObject(groupId: 0, objectId: 0)
        for _ in 0..<100 where subscription.handler.get() != nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(subscription.handler.get() == nil)
        for _ in 0..<100 where !participants.participants.compactMap(\.value).isEmpty {
            await Task.yield()
        }
        #expect(participants.participants.compactMap(\.value).isEmpty)
        _ = retainedHandler
    }

    @Test("Stopped subscription ignores late object delivery")
    @MainActor
    func testStoppedSubscriptionIgnoresLateObject() async throws {
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: {_ in},
                                    fetchCancel: {_ in})
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: 0,
                                                           ngThreshold: 0)

        subscription.stop()
        #expect(subscription.handler.get() == nil)

        subscription.mockObject(groupId: 0, objectId: 0)

        #expect(subscription.handler.get() == nil)
    }

    @Test("Stopping a handler waits out in-flight receive task creation")
    @MainActor
    func testHandlerStopPreventsInFlightDequeueTaskCreation() async throws {
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: {_ in},
                                    fetchCancel: {_ in})
        var jitterBufferConfig = JitterBuffer.Config()
        jitterBufferConfig.mode = .interval
        jitterBufferConfig.minDepth = 0
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: 0,
                                                           ngThreshold: 0,
                                                           jitterBufferConfig: jitterBufferConfig)
        let currentHandler = subscription.handler.get()
        let handler = try #require(currentHandler)
        let receiveEntered = DispatchSemaphore(value: 0)
        let resumeReceive = DispatchSemaphore(value: 0)
        _ = handler.registerCallback { _ in
            receiveEntered.signal()
            resumeReceive.wait()
        }

        let receiveTask = Task.detached {
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(1))
            try? extensions.setHeader(.captureTimestamp(.now))
            let priority: UInt8 = 0
            let ttl: UInt16 = 0
            withUnsafePointer(to: priority) { priorityPtr in
                withUnsafePointer(to: ttl) { ttlPtr in
                    handler.objectReceived(.init(groupId: 0,
                                                 subgroupId: 0,
                                                 objectId: 0,
                                                 payloadLength: 1,
                                                 status: .available,
                                                 priority: priorityPtr,
                                                 ttl: ttlPtr),
                                           data: Data([0x01]),
                                           extensions: extensions,
                                           when: .now,
                                           cached: false,
                                           drop: false)
                }
            }
        }
        let entered = await Task.detached {
            receiveEntered.wait(timeout: .now() + 2) == .success
        }.value
        guard entered else {
            resumeReceive.signal()
            await receiveTask.value
            Issue.record("Receive callback did not reach the synchronization point")
            return
        }

        handler.stop()
        resumeReceive.signal()
        await receiveTask.value

        #expect(handler.jitterBuffer == nil)
    }

    @Test("Stopping a subscription cancels and rejects an active fetch")
    @MainActor
    func testStopCancelsActiveFetch() async throws {
        var fetch: Fetch?
        var fetchCancelled = false
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: { fetch = $0 },
                                    fetchCancel: {_ in fetchCancelled = true})
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: self.fetchThreshold,
                                                           ngThreshold: self.ngThreshold)
        var extensions = HeaderExtensions()
        try extensions.setHeader(.sequenceNumber(1))
        try extensions.setHeader(.captureTimestamp(.now))
        subscription.mockObject(groupId: 0,
                                objectId: self.fetchThreshold - 1,
                                immutableExtensions: extensions)
        let activeFetch = try #require(fetch)
        guard case .fetching = subscription.getCurrentState() else {
            Issue.record("Expected an active fetch before stopping")
            return
        }

        subscription.stop()

        try #require(fetchCancelled)
        #expect(subscription.handler.get() == nil)
        activeFetch.objectReceived(.init(groupId: 0,
                                         subgroupId: 0,
                                         objectId: self.fetchThreshold - 2,
                                         payloadLength: 1,
                                         status: .available,
                                         priority: nil,
                                         ttl: nil),
                                   data: Data([0x01]),
                                   extensions: nil,
                                   immutableExtensions: nil,
                                   streamHeaderProperties: nil)
        #expect(subscription.handler.get() == nil)
        #expect(subscription.getCurrentState() == .startup)
    }

    @Test("In-flight fetch completion cannot undo subscription stop")
    @MainActor
    func testStopWinsRaceWithFetchCompletion() async throws {
        var fetch: Fetch?
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: { fetch = $0 },
                                    fetchCancel: {_ in})
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: self.fetchThreshold,
                                                           ngThreshold: self.ngThreshold)
        var extensions = HeaderExtensions()
        try extensions.setHeader(.sequenceNumber(1))
        try extensions.setHeader(.captureTimestamp(.now))
        subscription.mockObject(groupId: 0,
                                objectId: self.fetchThreshold - 1,
                                immutableExtensions: extensions)
        let activeFetch = try #require(fetch)
        let currentHandler = subscription.handler.get()
        let handler = try #require(currentHandler)
        let receiveEntered = DispatchSemaphore(value: 0)
        let resumeReceive = DispatchSemaphore(value: 0)
        _ = handler.registerCallback { _ in
            receiveEntered.signal()
            resumeReceive.wait()
        }

        let fetchTask = Task.detached {
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(2))
            try? extensions.setHeader(.captureTimestamp(.now))
            activeFetch.objectReceived(.init(groupId: 0,
                                             subgroupId: 0,
                                             objectId: self.fetchThreshold - 2,
                                             payloadLength: 1,
                                             status: .available,
                                             priority: nil,
                                             ttl: nil),
                                       data: Data([0x01]),
                                       extensions: nil,
                                       immutableExtensions: extensions,
                                       streamHeaderProperties: nil)
        }
        let entered = await Task.detached {
            receiveEntered.wait(timeout: .now() + 2) == .success
        }.value
        guard entered else {
            resumeReceive.signal()
            await fetchTask.value
            Issue.record("Fetched object did not reach the synchronization point")
            return
        }

        subscription.stop()
        resumeReceive.signal()
        await fetchTask.value

        #expect(subscription.handler.get() == nil)
        #expect(subscription.getCurrentState() == .startup)
    }

    @Test("Non-simulreceive receipt metrics preserve the first dropped sample")
    @MainActor
    func testHandlerReceiptMetricsPreserveFirstDrop() async throws {
        let participants = VideoParticipants()
        let activeSpeakerStats = ActiveSpeakerStats(nil)
        let mockClient = MockClient(publish: {_ in},
                                    unpublish: {_ in},
                                    subscribe: {_ in},
                                    unsubscribe: {_ in},
                                    fetch: {_ in},
                                    fetchCancel: {_ in})
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: 0,
                                                           ngThreshold: 0,
                                                           participants: participants,
                                                           activeSpeakerStats: activeSpeakerStats)
        let currentHandler = subscription.handler.get()
        let handler = try #require(currentHandler)
        for _ in 0..<100 where participants.participants.compactMap(\.value).isEmpty {
            await Task.yield()
        }
        try #require(!participants.participants.compactMap(\.value).isEmpty)

        let base = Ticks.now
        let first = base + TimeInterval(1).ticks
        var latest = base
        for index in 1...100 {
            latest = base + TimeInterval(index).ticks
            handler.objectReceived(.init(groupId: 0,
                                         subgroupId: 0,
                                         objectId: UInt64(index),
                                         payloadLength: 0,
                                         status: .available,
                                         priority: nil,
                                         ttl: nil),
                                   data: .init(),
                                   extensions: nil,
                                   when: latest,
                                   cached: false,
                                   drop: true)
        }
        for _ in 0..<100 {
            await Task.yield()
        }

        await activeSpeakerStats.dataReceived(.init(1), when: latest.hostDate)
        let result = try await activeSpeakerStats.imageEnqueued(.init(1),
                                                                when: latest.hostDate)
        #expect(result.dropped == first.hostDate)
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

    @Test("Cleanup fetch waits for a decodable GOP")
    @MainActor
    func testCleanupFetchWaitsForGOP() async throws {
        var fetchCancelled = false
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { _ in },
                                    fetchCancel: { _ in fetchCancelled = true })
        var jitterBufferConfig = JitterBuffer.Config()
        jitterBufferConfig.mode = .interval
        jitterBufferConfig.minDepth = 0
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold,
                                                           jitterBufferConfig: jitterBufferConfig,
                                                           cleanupTime: 0.2)

        var sequence: UInt64 = 0
        func loc() -> HeaderExtensions {
            sequence += 1
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(sequence))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        subscription.mockObject(groupId: 0, objectId: 0, immutableExtensions: loc())
        for _ in 0..<100 where subscription.handler.get() != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(subscription.handler.get() == nil)

        // Cleanup recreated the handler. An early P-frame starts FETCH but must not release playout.
        subscription.mockObject(groupId: 1, objectId: 1, immutableExtensions: loc())
        try await Task.sleep(for: .milliseconds(75))
        guard case .fetching = subscription.getCurrentState() else {
            Issue.record("Expected fetching state, got \(subscription.getCurrentState())")
            return
        }
        let recreatedHandler = subscription.handler.get()
        let fetchingHandler = try #require(recreatedHandler)
        let queuedPFrame: DecimusVideoFrameJitterItem? = fetchingHandler.jitterBuffer?.peek()
        #expect(queuedPFrame?.frame.objectId == 1)
        #expect(!fetchCancelled)

        // A newer live GOP is also a valid release: cancel FETCH and play through any decodable prefix.
        subscription.mockObject(groupId: 2, objectId: 0, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)
        #expect(fetchCancelled)
        for _ in 0..<100 {
            let queued: DecimusVideoFrameJitterItem? = fetchingHandler.jitterBuffer?.peek()
            guard queued != nil else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let queuedAfterRelease: DecimusVideoFrameJitterItem? = fetchingHandler.jitterBuffer?.peek()
        #expect(queuedAfterRelease == nil)
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
                                 immutableExtensions: loc(),
                                 streamHeaderProperties: nil)
        }

        // State should remain startup (not transition to running)
        #expect(subscription.getCurrentState() == .startup)
    }

    /// Helper to get a subscription into running state.
    @MainActor
    private func makeRunningSubscription(_ mockClient: MockClient) async throws -> VideoSubscription {
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
        subscription.mockObject(groupId: 0, objectId: 0, extensions: nil, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)
        return subscription
    }

    @Test("Missed IDR mid-stream triggers fetch when early in group")
    @MainActor
    func testMissedIDRFetch() async throws {
        var fetch: Fetch?
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { fetch = $0 },
                                    fetchCancel: { _ in })
        let subscription = try await self.makeRunningSubscription(mockClient)

        // New group, early object — should trigger fetch.
        subscription.mockObject(groupId: 1, objectId: fetchThreshold - 1)
        switch subscription.getCurrentState() {
        case .fetching(let fetching):
            let startLocation = fetching.getStartLocation()
            let endLocation = fetching.getEndLocation()
            #expect(startLocation.group == 1)
            #expect(startLocation.object == 0)
            #expect(endLocation.group == 1)
            #expect(endLocation.object?.uint64Value == fetchThreshold - 2)
            #expect(fetch == fetching)
        default:
            #expect(Bool(false), "Expected fetching state, got \(subscription.getCurrentState())")
        }
    }

    @Test("Missed IDR mid-stream requests new group when mid group")
    @MainActor
    func testMissedIDRNewGroup() async throws {
        var fetch: Fetch?
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { fetch = $0 },
                                    fetchCancel: { _ in })
        let subscription = try await self.makeRunningSubscription(mockClient)

        // New group, past fetch threshold — should request new group.
        subscription.mockObject(groupId: 1, objectId: fetchThreshold)
        switch subscription.getCurrentState() {
        case .waitingForNewGroup(let requested):
            #expect(requested)
        default:
            #expect(Bool(false), "Expected waitingForNewGroup state, got \(subscription.getCurrentState())")
        }
        #expect(fetch == nil)
    }

    @Test("Missed IDR mid-stream waits for new group when late in group")
    @MainActor
    func testMissedIDRLate() async throws {
        var fetch: Fetch?
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { fetch = $0 },
                                    fetchCancel: { _ in })
        let subscription = try await self.makeRunningSubscription(mockClient)

        // New group, past new group threshold — should wait without requesting.
        subscription.mockObject(groupId: 1, objectId: ngThreshold)
        switch subscription.getCurrentState() {
        case .waitingForNewGroup(let requested):
            #expect(!requested)
        default:
            #expect(Bool(false), "Expected waitingForNewGroup state, got \(subscription.getCurrentState())")
        }
        #expect(fetch == nil)
    }

    @Test("Handler requests new group after a same-group discontinuity")
    @MainActor
    func testHandlerDiscontinuityRequestsNewGroup() async throws {
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { _ in #expect(Bool(false), "Should not fetch") },
                                    fetchCancel: { _ in })
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold,
                                                           cleanupTime: 60)

        var sequence: UInt64 = 0
        func loc() -> HeaderExtensions {
            sequence += 1
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(sequence))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        subscription.mockObject(groupId: 0, objectId: 0, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)

        subscription.mockObject(groupId: 0, objectId: 2, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .waitingForNewGroup(true))

        // Further P-frames remain dropped without starting another recovery.
        subscription.mockObject(groupId: 0, objectId: 3, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .waitingForNewGroup(true))

        subscription.mockObject(groupId: 1, objectId: 0, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)
    }

    @Test("Old handler can't start recovery on new handler")
    @MainActor
    func testCleanedUpHandlerCannotStartRecovery() async throws {
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { _ in #expect(Bool(false), "Should not fetch") },
                                    fetchCancel: { _ in })
        let subscription = try await self.makeSubscription(mockClient,
                                                           fetchThreshold: fetchThreshold,
                                                           ngThreshold: ngThreshold,
                                                           cleanupTime: 0.2)

        var sequence: UInt64 = 0
        func loc() -> HeaderExtensions {
            sequence += 1
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(sequence))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        let originalHandler = subscription.handler.get()
        let cleanedUpHandler = try #require(originalHandler)
        subscription.mockObject(groupId: 0, objectId: 0, immutableExtensions: loc())
        for _ in 0..<100 where subscription.handler.get() != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let handlerAfterCleanup = subscription.handler.get()
        #expect(handlerAfterCleanup == nil)

        subscription.mockObject(groupId: 1, objectId: 0, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)

        let priority: UInt8 = 0
        let ttl: UInt16 = 0
        withUnsafePointer(to: priority) { priorityPtr in
            withUnsafePointer(to: ttl) { ttlPtr in
                cleanedUpHandler.objectReceived(.init(groupId: 0,
                                                      subgroupId: 0,
                                                      objectId: 2,
                                                      payloadLength: 0,
                                                      status: .available,
                                                      priority: priorityPtr,
                                                      ttl: ttlPtr),
                                                data: Data([0x01]),
                                                extensions: loc(),
                                                when: .now,
                                                cached: false,
                                                drop: false)
            }
        }
        #expect(subscription.getCurrentState() == .running)
    }

    @Test("Same group objects while running do not trigger missed IDR")
    @MainActor
    func testSameGroupNoMissedIDR() async throws {
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { _ in #expect(Bool(false), "Should not fetch") },
                                    fetchCancel: { _ in })
        let subscription = try await self.makeRunningSubscription(mockClient)

        var sequence: UInt64 = 100
        func loc() -> HeaderExtensions {
            sequence += 1
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(sequence))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        // Same group, later objects — should stay running.
        subscription.mockObject(groupId: 0, objectId: 1, extensions: nil, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)
        subscription.mockObject(groupId: 0, objectId: 2, extensions: nil, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)
    }

    @Test("New group IDR received while running stays running")
    @MainActor
    func testNewGroupIDRReceived() async throws {
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { _ in #expect(Bool(false), "Should not fetch") },
                                    fetchCancel: { _ in })
        let subscription = try await self.makeRunningSubscription(mockClient)

        var sequence: UInt64 = 100
        func loc() -> HeaderExtensions {
            sequence += 1
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(sequence))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        // New group starting with IDR — should stay running.
        subscription.mockObject(groupId: 1, objectId: 0, extensions: nil, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)

        // Subsequent objects from that group should also be fine.
        subscription.mockObject(groupId: 1, objectId: 1, extensions: nil, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)
    }

    @Test("Late objects from prior group do not trigger missed IDR")
    @MainActor
    func testOutOfOrderGroupDelivery() async throws {
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { _ in #expect(Bool(false), "Should not fetch") },
                                    fetchCancel: { _ in })
        let subscription = try await self.makeRunningSubscription(mockClient)

        var sequence: UInt64 = 100
        func loc() -> HeaderExtensions {
            sequence += 1
            var extensions = HeaderExtensions()
            try? extensions.setHeader(.sequenceNumber(sequence))
            try? extensions.setHeader(.captureTimestamp(.now))
            return extensions
        }

        // Receive some objects from group 0.
        subscription.mockObject(groupId: 0, objectId: 1, extensions: nil, immutableExtensions: loc())
        subscription.mockObject(groupId: 0, objectId: 2, extensions: nil, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)

        // Group 1 IDR arrives before group 0 finishes.
        subscription.mockObject(groupId: 1, objectId: 0, extensions: nil, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)

        // Late objects from group 0 arrive — should not trigger missed IDR.
        subscription.mockObject(groupId: 0, objectId: 3, extensions: nil, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)
        subscription.mockObject(groupId: 0, objectId: 4, extensions: nil, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)

        // Group 1 continues normally.
        subscription.mockObject(groupId: 1, objectId: 1, extensions: nil, immutableExtensions: loc())
        #expect(subscription.getCurrentState() == .running)
    }

    @Test("Late prior-group IDR does not regress current group")
    @MainActor
    func testLatePriorGroupIDRDoesNotRegressCurrentGroup() async throws {
        let mockClient = MockClient(publish: { _ in },
                                    unpublish: { _ in },
                                    subscribe: { _ in },
                                    unsubscribe: { _ in },
                                    fetch: { _ in #expect(Bool(false), "Should not fetch") },
                                    fetchCancel: { _ in })
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

        subscription.mockObject(groupId: 0, objectId: 0, immutableExtensions: loc())
        subscription.mockObject(groupId: 1, objectId: 0, immutableExtensions: loc())
        subscription.mockObject(groupId: 0, objectId: 0, immutableExtensions: loc())
        subscription.mockObject(groupId: 1, objectId: 1, immutableExtensions: loc())

        #expect(subscription.getCurrentState() == .running)
    }
}
