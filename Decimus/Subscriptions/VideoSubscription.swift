// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

// swiftlint:disable file_length

import Foundation
import SFrame
import Synchronization

/// Represents a QuicR video subscription.
/// Holds an object for decoding & rendering.
/// Manages lifetime of said renderer.
/// Forwards data from callbacks.
class VideoSubscription: Subscription, @unchecked Sendable {
    typealias Callback = @Sendable (_ subscription: VideoSubscription,
                                    _ details: ObjectReceived) -> Void
    typealias VideoStatusCallback = @Sendable (_ subscription: VideoSubscription,
                                               _ status: QSubscribeTrackHandlerStatus) -> Void
    typealias HandlerStoppedCallback = @Sendable (_ subscription: VideoSubscription) -> Void

    struct JoinConfig<T: Codable>: Codable {
        var fetchUpperThreshold: T
        var newGroupUpperThreshold: T
    }

    /// Configuration for the video subscription.
    struct Config {
        /// Configuration for joining flow behaviour (FETCH/NEWGROUP).
        let joinConfig: JoinConfig<UInt64>
        /// Whether to calculate/display latency metrics.
        let calculateLatency: Bool
        /// True for media interop mode.
        let mediaInterop: Bool
        /// Max decode queue size.
        let decodeQueueSize: Int
    }

    private let fullTrackName: FullTrackName
    private let config: VideoCodecConfig
    private let participants: VideoParticipants
    private let metricsSubmitter: MetricsSubmitter?
    private let videoBehaviour: VideoBehaviour
    private let granularMetrics: Bool
    private let jitterBufferConfig: JitterBuffer.Config
    private let simulreceive: SimulreceiveMode
    private let variances: VarianceCalculator
    private let callback: Callback
    private let videoStatusChanged: VideoStatusCallback
    private let onHandlerStopped: HandlerStoppedCallback
    private var token: Int = 0
    private let logger: DecimusLogger
    private let verbose: Bool
    private let subscriptionConfig: Config
    private let joinConfig: JoinConfig<UInt64>

    let handler: Mutex<VideoHandler?>
    private let switchContext = Mutex<SwitchContext?>(nil)
    private var handlerCreatedOnce = false  // Only accessed inside handler.withLock

    private var cleanupTask: Task<(), Never>?
    private let cleanupTimer: TimeInterval
    private let lastUpdateTime = Atomic<Ticks>(.now)
    private let participantId: ParticipantId
    private let creationDate: Date
    private let joinDate: Date
    private let activeSpeakerStats: ActiveSpeakerStats?
    private let endpointId: String
    private let relayId: String
    private let controller: MoqCallController
    private var fetch: Fetch?
    private var fetched = false
    private let sframeContext: SFrameContext?
    private let wifiScanDetector: WiFiScanDetector?
    private let switchLatencyMeasurement: SwitchLatencyMeasurement?
    private let videoPipelineEvent: VideoPipelineEventCallback?
    private let videoObjectIngressInterceptor: VideoObjectIngressInterceptor?
    private var paused = false
    private var stopped = false
    // TODO: Refactor so we don't need recursion / use Mutex<T>
    private let lifecycleLock = NSRecursiveLock()
    private var lastSeenGroup: UInt64?
    private var maxGroupSeen: UInt64?
    private var handlerGeneration: UInt64 = 1
    private var delayedLiveTasks: [UUID: Task<Void, Never>] = [:]
    private var delayedFetchTasks: [UUID: Task<Void, Never>] = [:]

    // State machine.
    internal let stateMachine: StateMachine

    /// Possible states the video subscription can be in.
    internal enum State: Equatable {
        /// We're waiting to make a decision about how to join the video stream.
        case startup
        /// We're running as normal, passing to handler.
        case running
        /// We're currently fetching, processing fetched and live objects.
        case fetching(_ inProgress: Fetch)
        /// We're waiting for a new group to start, dropping anything else.
        case waitingForNewGroup(_ requested: Bool)
    }
    private enum StateMachineError: Error {
        case badTransition(_ from: State, _ to: State)
    }
    /// Models possible states and transitions for a video subscription.
    internal class StateMachine {
        private let controller: MoqCallController
        private let state = Mutex(State.startup)

        init(_ state: State, controller: MoqCallController) {
            self.controller = controller
            self.state.withLock { $0 = state }
        }

        /// Get current state.
        func get() -> State {
            self.state.get()
        }

        func waitForNewGroupIfRunning(_ requested: Bool) -> Bool {
            self.state.withLock { state in
                guard state == .running else { return false }
                state = .waitingForNewGroup(requested)
                return true
            }
        }

        func completeFetchIfActive(_ fetch: Fetch) -> Bool {
            self.state.withLock { state in
                guard case .fetching(let activeFetch) = state,
                      activeFetch === fetch else { return false }
                state = .running
                return true
            }
        }

        func transition(to newState: State) throws {
            try self.state.withLock { state in
                var valid: Bool {
                    switch state {
                    case .startup:
                        // Start->X is valid.
                        return true
                    case .running:
                        switch newState {
                        case .startup:
                            // Running->Startup on pause.
                            return true
                        case .fetching:
                            // Running->Fetching on missed IDR.
                            return true
                        case .waitingForNewGroup:
                            // Running->WaitingForNewGroup on missed IDR.
                            return true
                        default:
                            return false
                        }
                    case .fetching:
                        switch newState {
                        case .running:
                            // Fetching->Running when FETCH complete or cancelled.
                            return true
                        case .startup:
                            // Fetching->Startup on pause.
                            return true
                        default:
                            return false
                        }
                    case .waitingForNewGroup:
                        switch newState {
                        case .running:
                            // WaitingForNewGroup->Running when NEWGROUP received.
                            return true
                        case .startup:
                            // WaitingForNewGroup->Startup on pause.
                            return true
                        default:
                            return false
                        }
                    }
                }
                guard valid else { throw StateMachineError.badTransition(state, newState) }

                // Cancel fetch.
                switch state {
                case .fetching(let fetch):
                    if newState != .fetching(fetch) && !fetch.isComplete() {
                        do {
                            try self.controller.cancelFetch(fetch)
                        } catch {
                            print("Failed to cancel fetch during state transition: \(error.localizedDescription)")
                        }
                    }
                default:
                    break
                }

                state = newState
            }
        }
    }

    init(profile: Profile,
         config: VideoCodecConfig,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         videoBehaviour: VideoBehaviour,
         granularMetrics: Bool,
         jitterBufferConfig: JitterBuffer.Config,
         simulreceive: SimulreceiveMode,
         variances: VarianceCalculator,
         endpointId: String,
         relayId: String,
         participantId: ParticipantId,
         joinDate: Date,
         activeSpeakerStats: ActiveSpeakerStats?,
         controller: MoqCallController,
         verbose: Bool,
         cleanupTime: TimeInterval,
         subscriptionConfig: Config,
         sframeContext: SFrameContext?,
         wifiScanDetector: WiFiScanDetector?,
         switchLatencyMeasurement: SwitchLatencyMeasurement? = nil,
         videoPipelineEvent: VideoPipelineEventCallback? = nil,
         videoObjectIngressInterceptor: VideoObjectIngressInterceptor? = nil,
         publisherInitiated: Bool,
         callback: @escaping Callback,
         statusChanged: @escaping VideoStatusCallback,
         handlerStopped: @escaping HandlerStoppedCallback = { _ in }) throws {
        self.fullTrackName = try profile.getFullTrackName()
        self.config = config
        self.participants = participants
        self.metricsSubmitter = metricsSubmitter
        self.videoBehaviour = videoBehaviour
        self.granularMetrics = granularMetrics
        self.jitterBufferConfig = jitterBufferConfig
        self.simulreceive = simulreceive
        self.variances = variances
        self.callback = callback
        self.videoStatusChanged = statusChanged
        self.onHandlerStopped = handlerStopped
        self.participantId = participantId
        self.creationDate = .now
        self.joinDate = joinDate
        self.activeSpeakerStats = activeSpeakerStats
        self.controller = controller
        self.verbose = verbose
        self.relayId = relayId
        self.endpointId = endpointId
        self.cleanupTimer = cleanupTime
        self.subscriptionConfig = subscriptionConfig
        self.wifiScanDetector = wifiScanDetector
        self.switchLatencyMeasurement = switchLatencyMeasurement
        self.videoPipelineEvent = videoPipelineEvent
        self.videoObjectIngressInterceptor = videoObjectIngressInterceptor
        self.logger = .init(VideoSubscription.self, prefix: "\(self.fullTrackName)")
        let handlerConfig = VideoHandler.Config(calculateLatency: self.subscriptionConfig.calculateLatency,
                                                mediaInterop: self.subscriptionConfig.mediaInterop,
                                                decodeBufferSize: self.subscriptionConfig.decodeQueueSize)
        let handler = try VideoHandler(fullTrackName: fullTrackName,
                                       config: config,
                                       participants: participants,
                                       metricsSubmitter: metricsSubmitter,
                                       videoBehaviour: videoBehaviour,
                                       granularMetrics: granularMetrics,
                                       jitterBufferConfig: jitterBufferConfig,
                                       simulreceive: simulreceive,
                                       variances: variances,
                                       participantId: participantId,
                                       subscribeDate: self.creationDate,
                                       joinDate: joinDate,
                                       activeSpeakerStats: self.activeSpeakerStats,
                                       handlerConfig: handlerConfig,
                                       wifiDetector: self.wifiScanDetector,
                                       switchLatencyMeasurement: self.switchLatencyMeasurement,
                                       generation: self.handlerGeneration,
                                       videoPipelineEvent: self.videoPipelineEvent)
        self.handler = .init(handler)
        self.joinConfig = subscriptionConfig.joinConfig
        self.sframeContext = sframeContext
        self.stateMachine = .init(.startup, controller: self.controller)
        try super.init(fullTrackName: profile.getFullTrackName(),
                       endpointId: endpointId,
                       relayId: relayId,
                       metricsSubmitter: metricsSubmitter,
                       priority: 0,
                       groupOrder: .originalPublisherOrder,
                       filterType: .latestObject,
                       publisherInitiated: publisherInitiated,
                       deliveryTimeout: UInt64(profile.expiry?.first ?? 0),
                       statusCallback: nil)
        self.token = self.registerObjectCallback(for: handler)
        self.emit(.handlerCreated(.newSubscription), handlerGeneration: self.handlerGeneration)
        self.handlerCreatedOnce = true
        handler.setDiscontinuityCallback { [weak self, weak handler] groupId, objectId in
            guard let handler else { return }
            self?.handleDiscontinuity(from: handler, groupId: groupId, objectId: objectId)
        }
    }

    override func statusChanged(_ status: QSubscribeTrackHandlerStatus) {
        super.statusChanged(status)
        self.emit(.subscriptionStatus(String(describing: status)))
        self.videoStatusChanged(self, status)
    }

    private func emit(_ kind: VideoPipelineEvent.Kind,
                      handlerGeneration: UInt64? = nil,
                      renderEpoch: UInt64? = nil,
                      groupId: UInt64? = nil,
                      subgroupId: UInt64? = nil,
                      objectId: UInt64? = nil) {
        self.videoPipelineEvent?(VideoPipelineEvent(occurredAt: .now,
                                                    fullTrackName: self.fullTrackName,
                                                    handlerGeneration: handlerGeneration ?? self.handlerGeneration,
                                                    renderEpoch: renderEpoch,
                                                    groupId: groupId,
                                                    subgroupId: subgroupId,
                                                    objectId: objectId,
                                                    kind: kind))
    }

    private func registerObjectCallback(for handler: VideoHandler) -> Int {
        handler.registerCallback { [weak self, weak handler] details in
            guard let self,
                  let handler else { return }
            self.lifecycleLock.lock()
            defer { self.lifecycleLock.unlock() }
            guard self.handler.get() === handler else { return }
            self.callback(self, details)
        }
    }

    deinit {
        self.cleanupTask?.cancel()
        self.delayedLiveTasks.values.forEach { $0.cancel() }
        self.delayedFetchTasks.values.forEach { $0.cancel() }
        self.logger.debug("Deinit")
    }

    override func pause() {
        self.lifecycleLock.lock()
        defer { self.lifecycleLock.unlock() }
        guard !self.stopped else { return }

        // Stop objects being delivered.
        self.paused = true

        // When we pause, reset the state machine.
        try! self.stateMachine.transition(to: .startup) // swiftlint:disable:this force_try
        super.pause()
        self.logger.info("Paused")
    }

    override func resume() {
        self.lifecycleLock.lock()
        defer { self.lifecycleLock.unlock() }
        guard !self.stopped else { return }
        assert(self.paused, "Resume called when not paused")
        self.paused = false
        super.resume()
        self.logger.info("Resumed")
    }

    /// Stop the renderer owned by this subscription.
    func stop() {
        self.lifecycleLock.lock()
        defer { self.lifecycleLock.unlock() }
        guard !self.stopped else { return }
        self.stopped = true
        self.cleanupTask?.cancel()
        self.cleanupTask = nil
        self.cancelDelayedTasks()
        try! self.stateMachine.transition(to: .startup) // swiftlint:disable:this force_try
        self.stopHandler(reason: .subscriptionStopped)
    }

    private func stopHandler(reason: VideoHandlerStopReason) {
        let stoppedGeneration: UInt64? = self.handler.withLock { lockedHandler in
            guard let handler = lockedHandler else { return nil }
            handler.stop()
            lockedHandler = nil
            handler.unregisterCallback(self.token)
            self.token = 0
            return handler.generation
        }
        if let stoppedGeneration {
            self.emit(.handlerStopped(reason), handlerGeneration: stoppedGeneration)
            self.onHandlerStopped(self)
        }
    }

    private func cleanup() {
        self.lifecycleLock.lock()
        defer { self.lifecycleLock.unlock() }
        let inactiveFor = Ticks.now.timeIntervalSince(self.lastUpdateTime.load(ordering: .acquiring))
        guard !self.stopped,
              inactiveFor >= self.cleanupTimer else { return }
        self.stopHandler(reason: .inactiveCleanup)
        try! self.stateMachine.transition(to: .startup) // swiftlint:disable:this force_try
    }

    private func cancelDelayedTasks() {
        self.delayedLiveTasks.values.forEach { $0.cancel() }
        self.delayedFetchTasks.values.forEach { $0.cancel() }
        self.delayedLiveTasks.removeAll()
        self.delayedFetchTasks.removeAll()
    }

    private func handleDiscontinuity(from: VideoHandler, groupId: UInt64, objectId: UInt64) {
        self.lifecycleLock.lock()
        defer { self.lifecycleLock.unlock() }
        guard !self.stopped,
              !self.paused else { return }
        let requested = self.isNewGroupRequestSupported()
        let accepted = self.handler.withLock { currentHandler in
            guard currentHandler === from else { return false }
            return self.stateMachine.waitForNewGroupIfRunning(requested)
        }
        guard accepted else { return }
        if requested {
            self.emit(.joinDecision(.newGroup), handlerGeneration: from.generation,
                      groupId: groupId, objectId: objectId)
            self.emit(.newGroupRequested, handlerGeneration: from.generation,
                      groupId: groupId, objectId: objectId)
            self.requestNewGroup()
        }
    }

    /// What should happen to a video object based on state.
    enum Result {
        /// Process this object.
        /// ``start`` if playout should start as well.
        /// If a completed ``SwitchContext`` is attached, pass it through for measurement.
        case normal(_ start: Bool, switchContext: SwitchContext? = nil)
        /// Drop this object.
        case drop
    }

    internal func getCurrentState() -> VideoSubscription.State {
        self.stateMachine.get()
    }

    // swiftlint:disable force_try
    /// Handle a missed IDR: decide whether to fetch, request a new group, or wait.
    private func handleMissedIDR(objectHeaders: QObjectHeaders, switchContext: SwitchContext?) -> Result {
        // Store the context for the async join flow to complete.
        self.switchContext.withLock { $0 = switchContext }

        guard objectHeaders.objectId < self.joinConfig.newGroupUpperThreshold else {
            // Too far in, just wait.
            self.logger.debug("Dropping \(objectHeaders.groupId):\(objectHeaders.objectId) - Waiting for new group")
            try! self.stateMachine.transition(to: .waitingForNewGroup(false))
            self.switchContext.withLock { ctx in
                ctx?.joinStrategy = .wait
                ctx?.joinDecisionTime = .now
            }
            self.emit(.joinDecision(.wait), groupId: objectHeaders.groupId,
                      subgroupId: objectHeaders.subgroupId, objectId: objectHeaders.objectId)
            return .drop
        }

        guard objectHeaders.objectId < self.joinConfig.fetchUpperThreshold else {
            // Check new group supported.
            guard self.isNewGroupRequestSupported() else {
                self.logger.warning("Dropping \(objectHeaders.groupId):\(objectHeaders.objectId) - No dynamic groups")
                self.emit(.objectRejected(.joinState, "dynamic groups unsupported"),
                          groupId: objectHeaders.groupId, subgroupId: objectHeaders.subgroupId,
                          objectId: objectHeaders.objectId)
                return .drop
            }
            // Not close enough to the start, new group and wait.
            self.logger.debug("Dropping \(objectHeaders.groupId):\(objectHeaders.objectId) - Requesting new group")
            self.emit(.joinDecision(.newGroup), groupId: objectHeaders.groupId,
                      subgroupId: objectHeaders.subgroupId, objectId: objectHeaders.objectId)
            self.emit(.newGroupRequested, groupId: objectHeaders.groupId,
                      subgroupId: objectHeaders.subgroupId, objectId: objectHeaders.objectId)
            self.requestNewGroup()
            try! self.stateMachine.transition(to: .waitingForNewGroup(true))
            self.switchContext.withLock { ctx in
                ctx?.joinStrategy = .newGroup
                ctx?.joinDecisionTime = .now
            }
            return .drop
        }

        // Close to the start, FETCH.
        do {
            // Pause the handler while fetching.
            self.handler.get()?.pause()

            // Fetch the missing data.
            let fetch = try self.fetch(currentGroup: objectHeaders.groupId,
                                       currentObject: objectHeaders.objectId)
            try! self.stateMachine.transition(to: .fetching(fetch))
            self.switchContext.withLock { ctx in
                ctx?.joinStrategy = .fetch
                ctx?.joinDecisionTime = .now
            }
            self.emit(.joinDecision(.fetch), groupId: objectHeaders.groupId,
                      subgroupId: objectHeaders.subgroupId, objectId: objectHeaders.objectId)
            self.emit(.fetchRequested(startObject: 0, endObject: objectHeaders.objectId - 1),
                      groupId: objectHeaders.groupId, subgroupId: objectHeaders.subgroupId,
                      objectId: objectHeaders.objectId)
            // Process, don't play.
            return .normal(false)
        } catch {
            // Fallback to waiting for new group behaviour.
            self.logger.warning("Failed to start fetch: \(error.localizedDescription)")
            try! self.stateMachine.transition(to: .waitingForNewGroup(false))
            self.switchContext.withLock { ctx in
                ctx?.joinStrategy = .wait
                ctx?.joinDecisionTime = .now
            }
            self.emit(.joinDecision(.wait), groupId: objectHeaders.groupId,
                      subgroupId: objectHeaders.subgroupId, objectId: objectHeaders.objectId)
            return .drop
        }
    }

    private func determineState(objectHeaders: QObjectHeaders,
                                activation: ActivationType,
                                when: Ticks) -> Result {
        func makeSwitchContext() -> SwitchContext {
            .init(activationType: activation,
                  activationTime: when,
                  groupDepth: objectHeaders.objectId)
        }

        var getAction: Result { switch self.getCurrentState() {
        case .running:
            if objectHeaders.objectId == 0 {
                // IDR received, track the group.
                if self.lastSeenGroup.map({ objectHeaders.groupId >= $0 }) ?? true {
                    self.lastSeenGroup = objectHeaders.groupId
                }
                return .normal(false)
            }
            if objectHeaders.groupId > (self.lastSeenGroup ?? 0) {
                // Newer group without its IDR — missed it.
                self.logger.debug("Missed IDR for group \(objectHeaders.groupId)")
                return self.handleMissedIDR(objectHeaders: objectHeaders, switchContext: makeSwitchContext())
            }
            return .normal(false)
        case .fetching:
            if objectHeaders.objectId == 0 {
                self.logger.debug("The fetch has been overrun")
                try! self.stateMachine.transition(to: .running)
                self.lastSeenGroup = objectHeaders.groupId
                // Complete the stored context from when the fetch started.
                let ctx = self.switchContext.withLock { ctx in
                    ctx?.joinCompleteTime = when
                    let captured = ctx
                    ctx = nil
                    return captured
                }
                return .normal(true, switchContext: ctx)
            }
            // Carry on, but don't play yet.
            return .normal(false)
        case .startup:
            guard objectHeaders.objectId != 0 else {
                // We started on a group, play.
                self.logger.debug("No fetch needed")
                try! self.stateMachine.transition(to: .running)
                self.lastSeenGroup = objectHeaders.groupId
                var ctx = makeSwitchContext()
                ctx.joinStrategy = .idr
                ctx.joinDecisionTime = when
                ctx.joinCompleteTime = when
                self.emit(.joinDecision(.idr), groupId: objectHeaders.groupId,
                          subgroupId: objectHeaders.subgroupId, objectId: objectHeaders.objectId)
                return .normal(true, switchContext: ctx)
            }
            return self.handleMissedIDR(objectHeaders: objectHeaders, switchContext: makeSwitchContext())
        case .waitingForNewGroup:
            guard objectHeaders.objectId == 0 else {
                // Drop non-newgroup objects.
                if self.verbose {
                    self.logger.debug(
                        "Dropping \(objectHeaders.groupId):\(objectHeaders.objectId) while waiting for new group")
                }
                return .drop
            }
            // Start from this new group, play.
            try! self.stateMachine.transition(to: .running)
            self.lastSeenGroup = objectHeaders.groupId
            // Complete the stored context from when we started waiting.
            let ctx = self.switchContext.withLock { ctx in
                ctx?.joinCompleteTime = when
                let captured = ctx
                ctx = nil
                return captured
            }
            self.emit(.joinDecision(.idr), groupId: objectHeaders.groupId,
                      subgroupId: objectHeaders.subgroupId, objectId: objectHeaders.objectId)
            return .normal(true, switchContext: ctx)
        }
        }
        // swiftlint:enable force_try
        return getAction
    }

    override func objectReceived(_ objectHeaders: QObjectHeaders,
                                 data: Data,
                                 extensions: HeaderExtensions?,
                                 immutableExtensions: HeaderExtensions?,
                                 streamHeaderProperties: QStreamHeaderProperties?) {
        let effectiveExtensions = immutableExtensions ?? extensions
        let ingress = VideoObjectIngress(fullTrackName: self.fullTrackName,
                                         groupId: objectHeaders.groupId,
                                         subgroupId: objectHeaders.subgroupId,
                                         objectId: objectHeaders.objectId,
                                         payloadLength: objectHeaders.payloadLength,
                                         status: objectHeaders.status,
                                         activity: Self.audioActivity(in: effectiveExtensions),
                                         cached: false)
        self.emit(.objectReceived(cached: false, activity: ingress.activity),
                  groupId: ingress.groupId,
                  subgroupId: ingress.subgroupId,
                  objectId: ingress.objectId)
        switch self.videoObjectIngressInterceptor?(ingress) ?? .deliver {
        case .deliver:
            self.processLiveObject(ingress, objectHeaders: objectHeaders, data: data, extensions: effectiveExtensions)
        case .drop(let reason):
            self.emit(.objectRejected(.intercepted, reason),
                      groupId: ingress.groupId,
                      subgroupId: ingress.subgroupId,
                      objectId: ingress.objectId)
        case .delay(let seconds, _):
            guard seconds.isFinite, seconds > 0 else {
                self.emit(.objectRejected(.intercepted, "invalid delay: \(seconds)"),
                          groupId: ingress.groupId,
                          subgroupId: ingress.subgroupId,
                          objectId: ingress.objectId)
                return
            }
            self.scheduleDelayedLiveObject(ingress,
                                           objectHeaders: objectHeaders,
                                           data: data,
                                           extensions: effectiveExtensions,
                                           seconds: seconds)
        }
    }

    private func processLiveObject(_ ingress: VideoObjectIngress,
                                   objectHeaders: QObjectHeaders,
                                   data: Data,
                                   extensions: HeaderExtensions?) {
        self.lifecycleLock.lock()
        defer { self.lifecycleLock.unlock() }
        guard !self.stopped else {
            self.emit(.objectRejected(.stopped, nil), groupId: ingress.groupId,
                      subgroupId: ingress.subgroupId, objectId: ingress.objectId)
            return
        }

        // If we're paused, drop this.
        guard !self.paused else {
            if self.verbose {
                self.logger.debug("Dropping object while in app paused state: \(objectHeaders.groupId) \(objectHeaders.objectId)")
            }
            self.emit(.objectRejected(.paused, nil), groupId: ingress.groupId,
                      subgroupId: ingress.subgroupId, objectId: ingress.objectId)
            return
        }

        // Record the time this arrived.
        let now = Ticks.now
        self.lastUpdateTime.store(now, ordering: .releasing)

        // Per-frame logging.
        if self.verbose {
            self.logger.debug("Received: \(objectHeaders.groupId) \(objectHeaders.objectId)")
        }

        // Start the cleanup task, if not already.
        if self.cleanupTask == nil {
            self.cleanupTask = .init(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    let duration: TimeInterval
                    if let self = self {
                        duration = self.cleanupTimer
                        let last = self.lastUpdateTime.load(ordering: .acquiring)
                        if Ticks.now.timeIntervalSince(last) >= self.cleanupTimer {
                            self.cleanup()
                        }
                    } else {
                        return
                    }
                    try? await Task.sleep(for: .seconds(duration))
                }
            }
        }

        // Get a handler for video.
        let handler: VideoHandler
        let activation: ActivationType
        do {
            guard let created = try self.getCreateHandler() else {
                self.emit(.objectRejected(.handlerUnavailable, nil), groupId: ingress.groupId,
                          subgroupId: ingress.subgroupId, objectId: ingress.objectId)
                return
            }
            (handler, activation) = created
        } catch {
            self.logger.warning("Failed to recreate video handler: \(error.localizedDescription)")
            self.emit(.objectRejected(.handlerUnavailable, error.localizedDescription),
                      groupId: ingress.groupId, subgroupId: ingress.subgroupId, objectId: ingress.objectId)
            return
        }

        // Track the highest group seen for out-of-order tolerance.
        if let max = self.maxGroupSeen {
            self.maxGroupSeen = Swift.max(max, objectHeaders.groupId)
        } else {
            self.maxGroupSeen = objectHeaders.groupId
        }

        // Unprotect.
        let unprotected: Data
        if let sframeContext {
            do {
                unprotected = try sframeContext.mutex.withLock { try $0.unprotect(ciphertext: data) }
            } catch {
                self.logger.warning("Unprotect failure: \(error.localizedDescription)")
                self.emit(.objectRejected(.unprotect, error.localizedDescription),
                          handlerGeneration: handler.generation,
                          groupId: ingress.groupId, subgroupId: ingress.subgroupId, objectId: ingress.objectId)
                return
            }
        } else {
            unprotected = data
        }

        // Check for action & state change.
        func notify(drop: Bool) {
            handler.objectReceived(objectHeaders,
                                   data: unprotected,
                                   extensions: extensions,
                                   when: now,
                                   cached: false,
                                   drop: drop)
        }
        // TODO: Maybe this should be a locked mutex, but it's a big lock.
        guard !self.paused else {
            if self.verbose {
                self.logger.info("Dropping object - paused before state determination")
            }
            self.emit(.objectRejected(.paused, nil), handlerGeneration: handler.generation,
                      groupId: ingress.groupId, subgroupId: ingress.subgroupId, objectId: ingress.objectId)
            return
        }
        switch self.determineState(objectHeaders: objectHeaders,
                                   activation: activation,
                                   when: now) {
        case .drop:
            self.emit(.objectRejected(.joinState, String(describing: self.getCurrentState())),
                      handlerGeneration: handler.generation,
                      groupId: ingress.groupId, subgroupId: ingress.subgroupId, objectId: ingress.objectId)
            notify(drop: true)
            return
        case .normal(let start, let switchContext):
            notify(drop: false)
            if let switchContext, !start {
                // Join decision.
                handler.setPendingSwitchContext(switchContext)
            } else if start {
                self.logger.debug("Starting video playout - live")
                handler.play(switchContext: switchContext)
            }
        }
    }

    private func getCreateHandler() throws -> (handler: VideoHandler, activation: ActivationType)? {
        try self.handler.withLock { lockedHandler in
            guard !self.stopped else { return nil }
            if let existing = lockedHandler {
                return (existing, .existing)
            }
            self.handlerGeneration += 1
            let config = VideoHandler.Config(calculateLatency: self.subscriptionConfig.calculateLatency,
                                             mediaInterop: self.subscriptionConfig.mediaInterop,
                                             decodeBufferSize: self.subscriptionConfig.decodeQueueSize)
            let newHandler = try VideoHandler(fullTrackName: self.fullTrackName,
                                              config: self.config,
                                              participants: self.participants,
                                              metricsSubmitter: self.metricsSubmitter,
                                              videoBehaviour: self.videoBehaviour,
                                              granularMetrics: self.granularMetrics,
                                              jitterBufferConfig: self.jitterBufferConfig,
                                              simulreceive: self.simulreceive,
                                              variances: self.variances,
                                              participantId: self.participantId,
                                              subscribeDate: self.creationDate,
                                              joinDate: self.joinDate,
                                              activeSpeakerStats: self.activeSpeakerStats,
                                              handlerConfig: config,
                                              wifiDetector: self.wifiScanDetector,
                                              switchLatencyMeasurement: self.switchLatencyMeasurement,
                                              generation: self.handlerGeneration,
                                              videoPipelineEvent: self.videoPipelineEvent)
            newHandler.setDiscontinuityCallback { [weak self, weak newHandler] groupId, objectId in
                guard let newHandler else { return }
                self?.handleDiscontinuity(from: newHandler, groupId: groupId, objectId: objectId)
            }
            self.token = self.registerObjectCallback(for: newHandler)
            let activation: ActivationType = self.handlerCreatedOnce ? .reactivation : .newSubscription
            self.handlerCreatedOnce = true
            lockedHandler = newHandler
            self.emit(.handlerCreated(activation), handlerGeneration: newHandler.generation)
            return (newHandler, activation)
        }
    }

    private static func audioActivity(in extensions: HeaderExtensions?) -> UInt8? {
        guard let extensions,
              let value = try? extensions.getHeader(.audioActivityIndicator),
              case .audioActivityIndicator(let activity) = value else {
            return nil
        }
        return activity
    }

    private func scheduleDelayedLiveObject(_ ingress: VideoObjectIngress,
                                           objectHeaders: QObjectHeaders,
                                           data: Data,
                                           extensions: HeaderExtensions?,
                                           seconds: TimeInterval) {
        let id = UUID()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.removeDelayedLiveTask(id)
            self.processLiveObject(ingress, objectHeaders: objectHeaders, data: data, extensions: extensions)
        }
        self.lifecycleLock.lock()
        self.delayedLiveTasks[id] = task
        self.lifecycleLock.unlock()
    }

    private func removeDelayedLiveTask(_ id: UUID) {
        self.lifecycleLock.lock()
        self.delayedLiveTasks.removeValue(forKey: id)
        self.lifecycleLock.unlock()
    }

    private func fetch(currentGroup: UInt64, currentObject: UInt64) throws -> Fetch {
        // TODO: What should the priority be?
        assert(currentObject > 0, "Guard the overflow, should never fetch on 0th")
        self.logger.debug("Starting fetch for \(currentGroup):0->\(currentObject - 1)")
        let startLocation = QLocationImpl(group: currentGroup, object: 0)
        let endLocation = QFetchEndLocationImpl(group: currentGroup, object: NSNumber(value: currentObject - 1))
        let fetch = CallbackFetch(ftn: self.fullTrackName,
                                  priority: 0,
                                  groupOrder: .originalPublisherOrder,
                                  startLocation: startLocation,
                                  endLocation: endLocation,
                                  verbose: self.verbose,
                                  metricsSubmitter: self.metricsSubmitter,
                                  endpointId: self.endpointId,
                                  relayId: self.relayId,
                                  statusChanged: { [weak self] status in
                                    guard let self = self else { return }
                                    self.emit(.fetchStatus(String(describing: status)))
                                    let message = "Fetch status changed: \(status)"
                                    if !status.isError || (status == .notConnected) {
                                        self.logger.info(message)
                                    } else {
                                        self.logger.warning(message)
                                    }
                                  },
                                  objectReceived: { [weak self] fetch, headers, data, extensions, immutableExtensions in
                                    guard let self = self else { return }
                                    self.onFetchedObject(fetch: fetch,
                                                         headers: headers,
                                                         data: data,
                                                         extensions: extensions,
                                                         immutableExtensions: immutableExtensions,
                                                         currentGroup: currentGroup,
                                                         currentObject: currentObject)
                                  })
        try self.controller.fetch(fetch)
        return fetch
    }

    private func onFetchedObject(fetch: Fetch,
                                 headers: QObjectHeaders,
                                 data: Data,
                                 extensions: HeaderExtensions?,
                                 immutableExtensions: HeaderExtensions?,
                                 currentGroup: UInt64,
                                 currentObject: UInt64) {
        let effectiveExtensions = immutableExtensions ?? extensions
        let ingress = VideoObjectIngress(fullTrackName: self.fullTrackName,
                                         groupId: headers.groupId,
                                         subgroupId: headers.subgroupId,
                                         objectId: headers.objectId,
                                         payloadLength: headers.payloadLength,
                                         status: headers.status,
                                         activity: Self.audioActivity(in: effectiveExtensions),
                                         cached: true)
        self.emit(.objectReceived(cached: true, activity: ingress.activity),
                  groupId: ingress.groupId, subgroupId: ingress.subgroupId, objectId: ingress.objectId)
        switch self.videoObjectIngressInterceptor?(ingress) ?? .deliver {
        case .deliver:
            self.processFetchedObject(fetch: fetch, ingress: ingress, headers: headers, data: data,
                                      extensions: effectiveExtensions, currentGroup: currentGroup,
                                      currentObject: currentObject)
        case .drop(let reason):
            self.emit(.objectRejected(.intercepted, reason), groupId: ingress.groupId,
                      subgroupId: ingress.subgroupId, objectId: ingress.objectId)
        case .delay(let seconds, _):
            guard seconds.isFinite, seconds > 0 else {
                self.emit(.objectRejected(.intercepted, "invalid delay: \(seconds)"),
                          groupId: ingress.groupId, subgroupId: ingress.subgroupId, objectId: ingress.objectId)
                return
            }
            self.scheduleDelayedFetchObject(fetch: fetch, ingress: ingress, headers: headers, data: data,
                                            extensions: effectiveExtensions, currentGroup: currentGroup,
                                            currentObject: currentObject, seconds: seconds)
        }
    }

    private func processFetchedObject(fetch: Fetch,
                                      ingress: VideoObjectIngress,
                                      headers: QObjectHeaders,
                                      data: Data,
                                      extensions: HeaderExtensions?,
                                      currentGroup: UInt64,
                                      currentObject: UInt64) {
        self.lifecycleLock.lock()
        defer { self.lifecycleLock.unlock() }
        // TODO: Reduce duplication with objectReceived?
        guard !self.stopped else {
            self.emit(.objectRejected(.stopped, nil), groupId: ingress.groupId,
                      subgroupId: ingress.subgroupId, objectId: ingress.objectId)
            return
        }

        guard !self.paused else {
            if self.verbose {
                self.logger.info("Dropping fetched object in paused state")
            }
            self.emit(.objectRejected(.paused, nil), groupId: ingress.groupId,
                      subgroupId: ingress.subgroupId, objectId: ingress.objectId)
            return
        }

        guard case .fetching(let activeFetch) = self.stateMachine.get(),
              activeFetch === fetch else {
            if self.verbose {
                self.logger.info("Dropping object from inactive fetch")
            }
            self.emit(.objectRejected(.inactiveFetch, nil), groupId: ingress.groupId,
                      subgroupId: ingress.subgroupId, objectId: ingress.objectId)
            return
        }

        // Got an object from fetch.
        if self.verbose {
            self.logger.debug("Fetched: \(headers.groupId):\(headers.objectId)")
        }
        // TODO: This should be getCreate? Unsure if this would ever happen.
        guard let handler = self.handler.get() else {
            assert(self.stopped,
                   "Missing video handler while subscription is active")
            self.emit(.objectRejected(.handlerUnavailable, nil), groupId: ingress.groupId,
                      subgroupId: ingress.subgroupId, objectId: ingress.objectId)
            return
        }

        // Unprotect.
        let unprotected: Data
        if let sframeContext {
            do {
                unprotected = try sframeContext.mutex.withLock { try $0.unprotect(ciphertext: data) }
            } catch {
                self.logger.warning("Unprotect failure: \(error.localizedDescription)")
                self.emit(.objectRejected(.unprotect, error.localizedDescription),
                          handlerGeneration: handler.generation,
                          groupId: ingress.groupId, subgroupId: ingress.subgroupId, objectId: ingress.objectId)
                return
            }
        } else {
            unprotected = data
        }

        // Pass.
        handler.objectReceived(headers,
                               data: unprotected,
                               extensions: extensions,
                               when: .now,
                               cached: true,
                               drop: false)

        // Are we done?
        if headers.groupId == currentGroup,
           headers.objectId == currentObject - 1 {
            self.logger.info("Video Fetch complete")
            // Complete only while this fetch still owns the subscription state.
            let completed = self.stateMachine.completeFetchIfActive(fetch)
            guard completed else {
                if self.verbose {
                    self.logger.info("Not completing inactive fetch")
                }
                return
            }
            self.emit(.fetchCompleted, handlerGeneration: handler.generation,
                      groupId: headers.groupId, subgroupId: headers.subgroupId, objectId: headers.objectId)
            self.lastSeenGroup = currentGroup
            self.switchContext.withLock { ctx in
                ctx?.joinCompleteTime = .now
                ctx?.fetchObjectCount = currentObject
            }
            self.logger.debug("Starting video playout - fetch")
            handler.play(switchContext: self.switchContext.consume())
        }
    }

    private func scheduleDelayedFetchObject(
        fetch: Fetch,
        ingress: VideoObjectIngress,
        headers: QObjectHeaders,
        data: Data,
        extensions: HeaderExtensions?,
        currentGroup: UInt64,
        currentObject: UInt64,
        seconds: TimeInterval
    ) {
        let id = UUID()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.removeDelayedFetchTask(id)
            self.processFetchedObject(fetch: fetch, ingress: ingress, headers: headers, data: data,
                                      extensions: extensions, currentGroup: currentGroup,
                                      currentObject: currentObject)
        }
        self.lifecycleLock.lock()
        self.delayedFetchTasks[id] = task
        self.lifecycleLock.unlock()
    }

    private func removeDelayedFetchTask(_ id: UUID) {
        self.lifecycleLock.lock()
        self.delayedFetchTasks.removeValue(forKey: id)
        self.lifecycleLock.unlock()
    }
}
