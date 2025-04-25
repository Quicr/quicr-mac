// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

/// Represents a QuicR video subscription.
/// Holds an object for decoding & rendering.
/// Manages lifetime of said renderer.
/// Forwards data from callbacks.
class VideoSubscription: Subscription, DisplayNotification {
    typealias StatusChanged = (_ status: QSubscribeTrackHandlerStatus) -> Void
    struct JoinConfig<T: Codable>: Codable {
        var fetchUpperThreshold: T
        var newGroupUpperThreshold: T
    }
    struct Config {
        let joinConfig: JoinConfig<UInt64>
    }

    private let fullTrackName: FullTrackName
    private let config: VideoCodecConfig
    private let participants: VideoParticipants
    private let metricsSubmitter: MetricsSubmitter?
    private let videoBehaviour: VideoBehaviour
    private let reliable: Bool
    private let granularMetrics: Bool
    private let jitterBufferConfig: JitterBuffer.Config
    private let simulreceive: SimulreceiveMode
    private let variances: VarianceCalculator
    private let callback: ObjectReceived
    private var token: Int = 0
    private let logger = DecimusLogger(VideoSubscription.self)
    private let verbose: Bool
    private let subscriptionConfig: Config
    private let joinConfig: JoinConfig<UInt64>

    let handler: Mutex<VideoHandler?>

    private var cleanupTask: Task<(), Never>?
    private let cleanupTimer: TimeInterval
    private var lastUpdateTime = Date.now
    private let participantId: ParticipantId
    private let creationDate: Date
    private let joinDate: Date
    private let activeSpeakerStats: ActiveSpeakerStats?
    private let endpointId: String
    private let relayId: String
    private let controller: MoqCallController
    private var fetch: Fetch?
    private var fetched = false
    private let postCleanup = Atomic(false)
    private let displayCallbacks = Mutex<DisplayCallbacks>(.init())
    private var displayCallbackMapping: [Int: Int] = [:]

    // State machine.
    private var stateMachine = StateMachine()

    /// Possible states the video subscription can be in.
    private enum State: Equatable {
        /// We're waiting to make a decision about how to join the video stream.
        case startup
        /// We're running as normal, passing to handler.
        case running
        /// We're currently fetching, processing fetched and live objects.
        case fetching(_ inProgress: Fetch)
        /// We're waiting for a new group to start, dropping anything else.
        case waitingForNewGroup
    }
    private enum StateMachineError: Error {
        case badTransition(_ from: State, _ to: State)
    }
    /// Models possible states and transitions for a video subscription.
    private struct StateMachine {
        var state = State.startup
        func transition(to newState: State) throws -> Self {
            var result = self
            var valid: Bool {
                switch self.state {
                case .startup:
                    // Start->X is valid.
                    return true
                case .running:
                    // Running->X is invalid.
                    return false
                case .fetching:
                    switch newState {
                    case .running:
                        // Fetching->Running when FETCH complete or cancelled.
                        return true
                    default:
                        return false
                    }
                case .waitingForNewGroup:
                    switch newState {
                    case .running:
                        // WaitingForNewGroup->Running when NEWGROUP received.
                        return true
                    default:
                        return false
                    }
                }
            }
            guard valid else { throw StateMachineError.badTransition(self.state, newState) }
            result.state = newState
            return result
        }
    }
    private var mediaState = MediaState.subscribed
    private var stateChangeToken: Int?

    init(profile: Profile,
         config: VideoCodecConfig,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         videoBehaviour: VideoBehaviour,
         reliable: Bool,
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
         callback: @escaping ObjectReceived,
         statusChanged: @escaping StatusChanged) throws {
        self.fullTrackName = try profile.getFullTrackName()
        self.config = config
        self.participants = participants
        self.metricsSubmitter = metricsSubmitter
        self.videoBehaviour = videoBehaviour
        self.reliable = reliable
        self.granularMetrics = granularMetrics
        self.jitterBufferConfig = jitterBufferConfig
        self.simulreceive = simulreceive
        self.variances = variances
        self.callback = callback
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
        let handler = try VideoHandler(fullTrackName: fullTrackName,
                                       config: config,
                                       participants: participants,
                                       metricsSubmitter: metricsSubmitter,
                                       videoBehaviour: videoBehaviour,
                                       reliable: reliable,
                                       granularMetrics: granularMetrics,
                                       jitterBufferConfig: jitterBufferConfig,
                                       simulreceive: simulreceive,
                                       variances: variances,
                                       participantId: participantId,
                                       subscribeDate: self.creationDate,
                                       joinDate: joinDate,
                                       activeSpeakerStats: self.activeSpeakerStats)
        self.token = handler.registerCallback(callback)
        self.handler = .init(handler)
        self.joinConfig = subscriptionConfig.joinConfig
        try super.init(profile: profile,
                       endpointId: endpointId,
                       relayId: relayId,
                       metricsSubmitter: metricsSubmitter,
                       priority: 0,
                       groupOrder: .originalPublisherOrder,
                       filterType: .latestObject,
                       statusCallback: statusChanged)
        self.stateChangeToken = handler.registerDisplayCallback { [weak self] in
            guard let self = self else { return }
            self.transitionMediaState(.rendered)
        }
    }

    deinit {
        self.logger.debug("Deinit")
    }

    func getMediaState() -> MediaState {
        self.mediaState
    }

    func registerDisplayCallback(_ callback: @escaping DisplayNotification.DisplayCallback) -> Int {
        let token = self.displayCallbacks.store(callback)
        if let handler = self.handler.get() {
            let handlerToken = handler.registerDisplayCallback(callback)
            self.displayCallbackMapping[token] = handlerToken
        }
        return token
    }

    func unregisterDisplayCallback(_ token: Int) {
        if let mapping = self.displayCallbackMapping.removeValue(forKey: token) {
            if let handler = self.handler.get() {
                handler.unregisterDisplayCallback(mapping)
            }
        }
        self.displayCallbacks.remove(token)
    }

    private func cleanup() {
        self.handler.withLock { lockedHandler in
            guard let handler = lockedHandler else { return }
            lockedHandler = nil
            handler.unregisterCallback(self.token)
            if let stateChangeToken = self.stateChangeToken {
                handler.unregisterDisplayCallback(stateChangeToken)
            }
            for mapping in self.displayCallbackMapping {
                handler.unregisterDisplayCallback(mapping.value)
            }
            self.token = 0
        }
        self.postCleanup.store(true, ordering: .releasing)
        self.transitionMediaState(.subscribed)
    }

    /// What should happen to a video object based on state.
    enum Result {
        /// Process this object.
        /// ``start`` if playout should start as well.
        case normal(_ start: Bool)
        /// Drop this object.
        case drop
    }

    private func determineState(objectHeaders: QObjectHeaders) -> Result {
        // swiftlint:disable force_try
        var getAction: Result { switch self.stateMachine.state {
        case .running:
            // Process.
            return .normal(false)
        case .fetching(let fetch):
            if objectHeaders.objectId == 0 {
                // The in-progress FETCH has been overrun, cancel it, play.
                self.logger.debug("Cancelling in progress fetch")
                do {
                    try self.controller.cancelFetch(fetch)
                } catch {
                    self.logger.warning("Failed to cancel fetch: \(error.localizedDescription)")
                }
                self.stateMachine = try! self.stateMachine.transition(to: .running)
                return .normal(true)
            }
            // Carry on, but don't play yet.
            return .normal(false)
        case .startup:
            guard objectHeaders.objectId != 0 else {
                // We started on a group, play.
                self.logger.debug("No fetch needed")
                self.stateMachine = try! self.stateMachine.transition(to: .running)
                return .normal(true)
            }

            guard objectHeaders.objectId < self.joinConfig.newGroupUpperThreshold else {
                // Too far in, just wait.
                self.logger.debug("Waiting for new group")
                self.stateMachine = try! self.stateMachine.transition(to: .waitingForNewGroup)
                return .drop
            }

            guard objectHeaders.objectId < self.joinConfig.fetchUpperThreshold else {
                // Not close enough to the start, new group and wait.
                self.logger.debug("Requesting new group")
                self.requestNewGroup()
                self.stateMachine = try! self.stateMachine.transition(to: .waitingForNewGroup)
                return .drop
            }

            // Close to the start, FETCH.
            do {
                let fetch = try self.fetch(currentGroup: objectHeaders.groupId,
                                           currentObject: objectHeaders.objectId)
                self.stateMachine = try! self.stateMachine.transition(to: .fetching(fetch))
                // Process, don't play.
                return .normal(false)
            } catch {
                // Fallback to waiting for new group behaviour.
                self.logger.error("Failed to start fetch: \(error.localizedDescription)")

                self.stateMachine = try! self.stateMachine.transition(to: .waitingForNewGroup)
                return .drop
            }
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
            self.stateMachine = try! self.stateMachine.transition(to: .running)
            return .normal(true)
        }
        }
        // swiftlint:enable force_try

        // Override playout to true if we cleaned up.
        let action = getAction
        var start: Bool {
            switch action {
            case .normal(let start):
                guard !start else { return false }
                return self.postCleanup.compareExchange(expected: true,
                                                        desired: false,
                                                        ordering: .acquiringAndReleasing).exchanged
            default:
                return false
            }
        }
        return start ? .normal(true) : action
    }

    override func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        // Record the time this arrived.
        let now = Date.now
        self.lastUpdateTime = now
        self.transitionMediaState(.received)

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
                        if Date.now.timeIntervalSince(self.lastUpdateTime) >= self.cleanupTimer {
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
        do {
            handler = try self.getCreateHandler()
        } catch {
            self.logger.error("Failed to recreate video handler: \(error.localizedDescription)")
            return
        }

        // Check for action & state change.
        func notify(drop: Bool) {
            handler.objectReceived(objectHeaders,
                                   data: data,
                                   extensions: extensions,
                                   when: now,
                                   cached: false,
                                   drop: drop)
        }
        switch self.determineState(objectHeaders: objectHeaders) {
        case .drop:
            notify(drop: true)
            return
        case .normal(let start):
            notify(drop: false)
            if start {
                self.logger.debug("Starting video playout - live")
                handler.play()
            }
        }
    }

    private func getCreateHandler() throws -> VideoHandler {
        try self.handler.withLock { lockedHandler in
            let handler: VideoHandler
            if let unwrapped = lockedHandler {
                handler = unwrapped
            } else {
                let recreated = try VideoHandler(fullTrackName: self.fullTrackName,
                                                 config: self.config,
                                                 participants: self.participants,
                                                 metricsSubmitter: self.metricsSubmitter,
                                                 videoBehaviour: self.videoBehaviour,
                                                 reliable: self.reliable,
                                                 granularMetrics: self.granularMetrics,
                                                 jitterBufferConfig: self.jitterBufferConfig,
                                                 simulreceive: self.simulreceive,
                                                 variances: self.variances,
                                                 participantId: self.participantId,
                                                 subscribeDate: self.creationDate,
                                                 joinDate: self.joinDate,
                                                 activeSpeakerStats: self.activeSpeakerStats)
                self.token = recreated.registerCallback(self.callback)
                self.stateChangeToken = recreated.registerDisplayCallback { [weak self] in
                    guard let self = self else { return }
                    self.transitionMediaState(.rendered)
                }
                for callback in self.displayCallbacks.get().callbacks {
                    let token = recreated.registerDisplayCallback(callback.value)
                    self.displayCallbackMapping[callback.key] = token
                }
                lockedHandler = recreated
                handler = recreated
            }
            return handler
        }
    }

    private func fetch(currentGroup: UInt64, currentObject: UInt64) throws -> Fetch {
        // TODO: What should the priority be?
        self.logger.debug("Starting fetch for \(currentGroup):0->\(currentObject)")
        let fetch = CallbackFetch(ftn: self.fullTrackName,
                                  priority: 0,
                                  groupOrder: .originalPublisherOrder,
                                  startGroup: currentGroup,
                                  endGroup: currentGroup,
                                  startObject: 0,
                                  endObject: currentObject,
                                  verbose: self.verbose,
                                  metricsSubmitter: self.metricsSubmitter,
                                  endpointId: self.endpointId,
                                  relayId: self.relayId,
                                  statusChanged: { [weak self] status in
                                    guard let self = self else { return }
                                    let message = "Fetch status changed: \(status)"
                                    if !status.isError || (status == .notConnected
                                                            && self.stateMachine.state == .running) {
                                        self.logger.info(message)
                                    } else {
                                        self.logger.error(message)
                                    }
                                  },
                                  objectReceived: {[weak self] headers, data, extensions in
                                    guard let self = self else { return }
                                    self.onFetchedObject(headers: headers,
                                                         data: data,
                                                         extensions: extensions,
                                                         currentGroup: currentGroup,
                                                         currentObject: currentObject)
                                  })
        try controller.fetch(fetch)
        return fetch
    }

    private func onFetchedObject(headers: QObjectHeaders,
                                 data: Data,
                                 extensions: [NSNumber: Data]?,
                                 currentGroup: UInt64,
                                 currentObject: UInt64) {
        // Got an object from fetch.
        if self.verbose {
            self.logger.debug("Fetched: \(headers.groupId):\(headers.objectId)")
        }
        guard let handler = self.handler.get() else { return }
        handler.objectReceived(headers, data: data, extensions: extensions, when: .now, cached: true, drop: false)

        // Are we done?
        if headers.groupId == currentGroup,
           headers.objectId == currentObject - 1 {
            self.logger.info("Video Fetch complete")
            switch self.stateMachine.state {
            case .fetching(let fetch):
                do {
                    self.stateMachine = try self.stateMachine.transition(to: .running)
                    try self.controller.cancelFetch(fetch)
                } catch {
                    self.logger.warning("Failed to cancel fetch: \(error.localizedDescription)")
                }
            default:
                assert(false)
                self.logger.warning("Subscription in invalid state", alert: true)
            }
            self.logger.debug("Starting video playout - fetch")
            handler.play()
        }
    }

    private func transitionMediaState(_ newState: MediaState) {
        assert(self.mediaState != .subscribed || newState == .received)
        assert(self.mediaState != .rendered || newState == .subscribed)
        self.mediaState = newState
    }
}
