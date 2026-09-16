// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

// swiftlint:disable file_length

import CoreMedia
import Dispatch
import Synchronization

enum SimulreceiveMode: Codable, CaseIterable, Identifiable {
    case none
    case visualizeOnly
    case enable
    var id: Self { self }
}

struct AvailableImage {
    let image: CMSampleBuffer
    let fps: UInt
    let discontinous: Bool
}

struct SimulreceiveCoalescingState {
    private static let defaultAllowance: TimeInterval = 0.006
    private static let minimumAllowance: TimeInterval = 0.006
    private static let maximumAllowance: TimeInterval = 0.008
    private static let historyLimit = 60

    private var decodedSpreads: [TimeInterval] = []
    private var pendingPresentationTime: CMTime?
    private var pendingImages: [FullTrackName: AvailableImage] = [:]
    private var deadline: Date?

    var allowance: TimeInterval {
        guard let maximumSpread = self.decodedSpreads.max() else {
            return Self.defaultAllowance
        }
        return min(Self.maximumAllowance,
                   max(Self.minimumAllowance, maximumSpread * 1.25))
    }

    mutating func record(decodedSpread: TimeInterval) {
        // Larger spreads mean a representation is out of phase, not that sibling decoding needs more coalescing time.
        guard decodedSpread.isFinite,
              decodedSpread >= 0,
              decodedSpread <= Self.maximumAllowance else { return }
        self.decodedSpreads.append(decodedSpread)
        if self.decodedSpreads.count > Self.historyLimit {
            self.decodedSpreads.removeFirst(self.decodedSpreads.count - Self.historyLimit)
        }
    }

    mutating func candidates(from current: [FullTrackName: AvailableImage]) -> [FullTrackName: AvailableImage] {
        if self.pendingPresentationTime == nil {
            self.pendingPresentationTime = current.values
                .map(\.image.presentationTimeStamp)
                .min()
        }
        guard let pendingPresentationTime else { return [:] }
        for (fullTrackName, image) in current where image.image.presentationTimeStamp == pendingPresentationTime {
            self.pendingImages[fullTrackName] = image
        }
        return self.pendingImages
    }

    mutating func waitDuration(at now: Date,
                               presentationTime: CMTime,
                               availableQualityCount: Int,
                               expectedQualityCount: Int,
                               highestAvailablePristineWidth: Int32?,
                               expectedHighestWidth: Int32?,
                               highestQualityAdvanced: Bool) -> TimeInterval? {
        let allQualitiesAvailable = availableQualityCount >= expectedQualityCount
        let highestQualityAvailable = highestAvailablePristineWidth == expectedHighestWidth
        guard expectedQualityCount > 1,
              !allQualitiesAvailable,
              !highestQualityAvailable,
              !highestQualityAdvanced else {
            self.resetPending()
            return nil
        }

        if self.pendingPresentationTime != presentationTime || self.deadline == nil {
            self.pendingPresentationTime = presentationTime
            self.deadline = now.addingTimeInterval(self.allowance)
        }

        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else {
            self.resetPending()
            return nil
        }
        return remaining
    }

    mutating func reset() {
        self.decodedSpreads.removeAll(keepingCapacity: true)
        self.resetPending()
    }

    private mutating func resetPending() {
        self.pendingPresentationTime = nil
        self.pendingImages.removeAll(keepingCapacity: true)
        self.deadline = nil
    }
}

final class SimulreceiveRenderWakeup: Sendable {
    private struct Waiter {
        let token: UInt64
        let continuation: CheckedContinuation<Void, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private struct State {
        var nextToken: UInt64 = 0
        var pendingSignal = false
        var cancelledTokens: Set<UInt64> = []
        var waiters: [UInt64: Waiter] = [:]
    }

    private let state = Mutex(State())

    func signal() {
        let waiters = self.state.withLock { state -> [Waiter] in
            guard !state.waiters.isEmpty else {
                state.pendingSignal = true
                return []
            }
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: true)
            return waiters
        }
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume()
        }
    }

    func wait(for duration: TimeInterval) async {
        guard duration > 0 else { return }
        let token = self.state.withLock { state in
            state.nextToken &+= 1
            return state.nextToken
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeImmediately = self.state.withLock { state in
                    if state.cancelledTokens.remove(token) != nil {
                        return true
                    }
                    if state.pendingSignal {
                        state.pendingSignal = false
                        return true
                    }
                    state.waiters[token] = .init(token: token,
                                                 continuation: continuation,
                                                 timeoutTask: nil)
                    return false
                }
                guard !resumeImmediately else {
                    continuation.resume()
                    return
                }

                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration), clock: .continuous)
                    guard !Task.isCancelled else { return }
                    self?.resume(token: token, cancelTimeout: false)
                }
                let installed = self.state.withLock { state in
                    guard state.waiters[token] != nil else { return false }
                    state.waiters[token]?.timeoutTask = timeoutTask
                    return true
                }
                if !installed {
                    timeoutTask.cancel()
                }
            }
        } onCancel: {
            let waiter = self.state.withLock { state -> Waiter? in
                guard let waiter = state.waiters.removeValue(forKey: token) else {
                    state.cancelledTokens.insert(token)
                    return nil
                }
                return waiter
            }
            waiter?.timeoutTask?.cancel()
            waiter?.continuation.resume()
        }
        self.state.withLock { _ = $0.cancelledTokens.remove(token) }
    }

    private func resume(token: UInt64, cancelTimeout: Bool) {
        let waiter = self.state.withLock { $0.waiters.removeValue(forKey: token) }
        if cancelTimeout {
            waiter?.timeoutTask?.cancel()
        }
        waiter?.continuation.resume()
    }
}

class VideoSubscriptionSet: ObservableSubscriptionSet, DisplayNotification, @unchecked Sendable {
    private let logger = DecimusLogger(VideoSubscriptionSet.self)

    private let subscription: ManifestSubscription
    private let participants: VideoParticipants
    private let submitter: MetricsSubmitter?
    private let videoBehaviour: VideoBehaviour
    private let granularMetrics: Bool
    private let jitterBufferConfig: JitterBuffer.Config
    private let simulreceive: SimulreceiveMode
    private var lastTime: CMTime?
    private var qualityMisses = 0
    private var qualityHits = 0
    private var last: FullTrackName?
    private var lastImage: AvailableImage?
    private let qualityMissThreshold: Int
    private var cleanupTask: Task<(), Never>?
    private let lastUpdateTime = Atomic<Ticks>(.now)
    private let profiles: [FullTrackName: VideoCodecConfig]
    private let cleanupTimer: TimeInterval
    private var pauseMissCounts: [FullTrackName: Int] = [:]
    private let pauseMissThreshold: Int
    private let pauseResume: Bool
    private var lastSimulreceiveLabel: String?
    private var lastHighlight: FullTrackName?
    private var lastDiscontinous = false
    private let measurement: VideoSubscriptionMeasurement?
    private let variances: VarianceCalculator
    let decodedVariances: VarianceCalculator
    private let subscribeDate: Date
    private let participant = Mutex<VideoParticipantRegistration?>(nil)
    private let membership = Mutex<Void>(())
    private let joinDate: Date
    private let activeSpeakerStats: ActiveSpeakerStats?
    private var timeAligner: TimeAligner?
    private let lastTimestampReceived = Atomic(Int64.zero)
    private let config: Config
    private let videoPipelineEvent: VideoPipelineEventCallback?

    /// State for simulreceive rendering.
    private struct RenderState {
        /// Rendering can go away and come back over time, this tracks which lifetime we're on.
        var epoch: UInt64 = 0
        /// Render task identifier.
        var nextToken: UInt64 = 0
        /// If set, a caller currently owns the task.
        var token: UInt64?
        /// The current simulreceive rendering task.
        var task: Task<Void, Never>?
    }
    /// Simulreceive render.
    private let renderState = Mutex(RenderState())
    /// Wakes the render task when a decoded image becomes available.
    private let renderWakeup = SimulreceiveRenderWakeup()
    /// Briefly coalesces sibling qualities that decode on slightly different timelines.
    private let coalescingState = Mutex(SimulreceiveCoalescingState())
    /// In flight decisions that should be allowed to complete.
    private let renderDecisions = DispatchGroup()

    /// Configuration for the video subscription set.
    struct Config {
        /// True to calculate / display end-to-end latency.
        let calculateLatency: Bool
        let qualityHitThreshold: Int

        /// Get a video participant config from this config.
        func getVideoParticipantConfig(_ set: VideoSubscriptionSet) -> VideoParticipant.Config {
            .init(calculateLatency: self.calculateLatency,
                  slidingWindowTime: set.jitterBufferConfig.window)
        }
    }

    init(subscription: ManifestSubscription,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         videoBehaviour: VideoBehaviour,
         granularMetrics: Bool,
         jitterBufferConfig: JitterBuffer.Config,
         simulreceive: SimulreceiveMode,
         qualityMissThreshold: Int,
         pauseMissThreshold: Int,
         pauseResume: Bool,
         endpointId: String,
         relayId: String,
         codecFactory: CodecFactory,
         joinDate: Date,
         activeSpeakerStats: ActiveSpeakerStats?,
         cleanupTime: TimeInterval,
         slidingWindowTime: TimeInterval,
         config: Config,
         videoPipelineEvent: VideoPipelineEventCallback? = nil) throws {
        if simulreceive != .none && jitterBufferConfig.mode == .layer {
            throw "Simulreceive and layer are not compatible"
        }

        self.subscription = subscription
        self.participants = participants
        self.submitter = metricsSubmitter
        if let submitter = metricsSubmitter {
            let measurement = VideoSubscriptionMeasurement(source: self.subscription.sourceID)
            submitter.register(measurement: measurement)
            self.measurement = measurement
        } else {
            self.measurement = nil
        }
        self.videoBehaviour = videoBehaviour
        self.granularMetrics = granularMetrics
        self.jitterBufferConfig = jitterBufferConfig
        self.simulreceive = simulreceive
        self.qualityMissThreshold = qualityMissThreshold
        self.pauseMissThreshold = pauseMissThreshold
        self.pauseResume = pauseResume
        let profiles = subscription.profileSet.profiles
        self.variances = try .init(expectedOccurrences: profiles.count,
                                   submitter: self.granularMetrics ? metricsSubmitter : nil,
                                   source: subscription.sourceID,
                                   stage: "SubscribedObject")
        self.decodedVariances = try .init(expectedOccurrences: profiles.count,
                                          submitter: self.granularMetrics ? metricsSubmitter : nil,
                                          source: subscription.sourceID,
                                          stage: "Decoded")

        let subscribeDate = Date.now
        self.subscribeDate = subscribeDate
        self.joinDate = joinDate
        self.activeSpeakerStats = activeSpeakerStats
        self.cleanupTimer = cleanupTime
        self.config = config
        self.videoPipelineEvent = videoPipelineEvent

        // Adjust and store expected quality profiles.
        var createdProfiles: [FullTrackName: VideoCodecConfig] = [:]
        for profile in profiles {
            let config = codecFactory.makeCodecConfig(from: profile.qualityProfile,
                                                      bitrateType: .average)
            guard let config = config as? VideoCodecConfig else {
                throw "Codec mismatch"
            }
            let fullTrackName = try profile.getFullTrackName()
            createdProfiles[fullTrackName] = config
        }

        // Store all the containing profiles.
        self.profiles = createdProfiles
        let maxFps = createdProfiles.values.reduce(into: 0) { $0 = max($0, Int($1.fps)) }
        let capacityGuess = TimeInterval(maxFps) * TimeInterval(createdProfiles.count) * slidingWindowTime

        // Base.
        super.init(sourceId: subscription.sourceID, participantId: subscription.participantId)

        // Prepare for aligning contained subscriptions to the same time line.
        self.timeAligner = .init(windowLength: slidingWindowTime,
                                 capacity: Int(capacityGuess)) { [weak self] in
            guard let self = self else { return [] }
            return self.getHandlers().compactMap { sub in
                let sub = sub.value as! VideoSubscription // swiftlint:disable:this force_cast
                return sub.handler.get()
            }
        }

        // Make task for cleaning up simulreceive rendering.
        if simulreceive == .enable {
            self.cleanupTask = .init(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    let time: TimeInterval
                    if let self = self {
                        time = self.cleanupTimer
                        self.membership.withLock { _ in
                            let lastUpdate = self.lastUpdateTime.load(ordering: .acquiring)
                            guard Ticks.now.timeIntervalSince(lastUpdate) >= self.cleanupTimer else { return }
                            self.suspendRendering()
                        }
                    } else {
                        return
                    }
                    try? await Task.sleep(for: .seconds(time),
                                          tolerance: .seconds(time),
                                          clock: .continuous)
                }
            }
        }

        self.logger.info("Subscribed to video stream")
    }

    private func emit(_ kind: VideoPipelineEvent.Kind,
                      fullTrackName: FullTrackName,
                      handlerGeneration: UInt64?,
                      epoch: UInt64,
                      groupId: UInt64? = nil,
                      objectId: UInt64? = nil) {
        self.videoPipelineEvent?(VideoPipelineEvent(occurredAt: .now,
                                                    fullTrackName: fullTrackName,
                                                    handlerGeneration: handlerGeneration,
                                                    renderEpoch: epoch,
                                                    groupId: groupId,
                                                    subgroupId: nil,
                                                    objectId: objectId,
                                                    kind: kind))
    }

    deinit {
        self.cleanupTask?.cancel()
        self.renderState.withLock { state in
            state.task?.cancel()
            state.token = nil
            state.task = nil
        }
        self.logger.debug("Deinit")
    }

    private func drainRenderTask() {
        self.renderState.withLock { state in
            state.epoch += 1
            state.task?.cancel()
            state.token = nil
            state.task = nil
        }
        self.renderDecisions.wait()
        self.last = nil
        self.lastImage = nil
        self.lastHighlight = nil
        self.qualityMisses = 0
        self.qualityHits = 0
        self.pauseMissCounts.removeAll()
        self.coalescingState.withLock { $0.reset() }
    }

    /// Get or create the participant for the locked render epoch.
    /// - Parameter state: The locked render state.
    /// - Parameter epoch: Which epoch we're calling from.
    @MainActor
    private func getOrCreateParticipant(state: inout RenderState,
                                        epoch: UInt64) throws -> VideoParticipantRegistration? {
        guard state.epoch == epoch else { return nil }
        return try self.participant.withLock { participant in
            guard !self.getHandlers().isEmpty else { return nil }
            if let participant {
                return participant
            }
            let new = VideoParticipant(id: self.sourceId,
                                       startDate: self.joinDate,
                                       subscribeDate: self.subscribeDate,
                                       participantId: self.participantId,
                                       activeSpeakerStats: self.activeSpeakerStats,
                                       config: self.config.getVideoParticipantConfig(self))
            let registration = try self.participants.register(new)
            participant = registration
            return registration
        }
    }

    private func removeParticipant() {
        guard let registration = self.participant.consume() else { return }
        registration.invalidate()
        Task { @MainActor in
            registration.remove()
        }
    }

    private func hasConcreteHandler() -> Bool {
        self.getHandlers().values.contains { subscription in
            (subscription as? VideoSubscription)?.handler.get() != nil
        }
    }

    private func suspendRendering() {
        self.drainRenderTask()
        self.removeParticipant()
        self.timeAligner?.reset()
        self.lastTimestampReceived.store(.zero, ordering: .releasing)
        self.mediaState.withLock { $0 = .subscribed }
    }

    private func reportParticipantReceipt(_ details: ObjectReceived, epoch: UInt64) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.renderState.withLock { state in
                    guard let registration = try self.getOrCreateParticipant(state: &state,
                                                                             epoch: epoch) else {
                        return
                    }
                    registration.withParticipant { participant in
                        participant.received(details)
                    }
                }
            } catch {
                self.logger.warning("Failed to create participant: \(error.localizedDescription)")
            }
        }
    }

    override func addHandler(_ handler: Subscription) throws {
        try self.membership.withLock { _ in
            try super.addHandler(handler)
        }
    }

    private func removeHandlerLocked(_ ftn: FullTrackName) -> Subscription? {
        guard let result = super.removeHandler(ftn) else { return nil }
        if self.hasConcreteHandler() {
            self.drainRenderTask()
        } else {
            if self.simulreceive == .enable {
                self.logger.debug("Destroying simulreceive render as no live subscriptions")
            }
            self.suspendRendering()
        }
        return result
    }

    override func removeHandler(_ ftn: FullTrackName) -> Subscription? {
        let result = self.membership.withLock { _ in
            self.removeHandlerLocked(ftn)
        }
        (result as? VideoSubscription)?.stop()
        return result
    }

    /// Remove a subscription only if it is still the registered instance for its track name.
    func removeHandler(_ subscription: VideoSubscription) -> Subscription? {
        let ftn = FullTrackName(subscription.getFullTrackName())
        let result: Subscription? = self.membership.withLock { _ in
            guard self.getHandlers()[ftn] === subscription else { return nil }
            return self.removeHandlerLocked(ftn)
        }
        (result as? VideoSubscription)?.stop()
        return result
    }

    /// Inform the set that a video frame from a managed subscription arrived.
    /// - Parameter subscription: The subscription this object came from.
    /// - Parameter timestamp: Media timestamp of the arrived frame, if usable.
    /// - Parameter when: The local datetime this happened.
    /// - Parameter cached: True if this object is cached.
    /// - Parameter usable: True if this object should be used.
    func receivedObject(_ subscription: VideoSubscription, details: ObjectReceived) {
        self.membership.withLock { _ in
            let ftn = FullTrackName(subscription.getFullTrackName())
            guard self.getHandlers()[ftn] === subscription else { return }
            self.receiveCurrentObject(details)
        }
    }

    func handlerStopped(_ subscription: VideoSubscription) {
        guard self.simulreceive != .none else { return }
        self.membership.withLock { _ in
            let ftn = FullTrackName(subscription.getFullTrackName())
            guard self.getHandlers()[ftn] === subscription else { return }
            if self.hasConcreteHandler() {
                self.drainRenderTask()
            } else {
                self.suspendRendering()
            }
        }
    }

    private func receiveCurrentObject(_ details: ObjectReceived) {
        let epoch = self.renderState.withLock { $0.epoch }

        // Notify receipt for stats.
        if self.simulreceive == .enable {
            let report: Bool
            if let timestamp = details.timestamp {
                let timestamp = Int64(timestamp * microsecondsPerSecond)
                let lastTimestamp = self.lastTimestampReceived.load(ordering: .acquiring)
                if timestamp <= lastTimestamp {
                    report = false
                } else {
                    self.lastTimestampReceived.store(timestamp, ordering: .releasing)
                    report = true
                }
            } else {
                report = true
            }

            if report {
                self.reportParticipantReceipt(details, epoch: epoch)
            }
        }

        if let timestamp = details.timestamp {
            // Set the timestamp diff using the min value from recent live objects.
            if !details.cached {
                self.timeAligner!.doTimestampTimeDiff(timestamp, when: details.when)
            }

            // Calculate switching set arrival variance.
            _ = self.variances.calculateSetVariance(timestamp: timestamp, now: details.when.hostDate)
        }

        // If we're responsible for rendering.
        if self.simulreceive != .none {
            self.startRenderTask(epoch: epoch)
        }

        // Record the last time this updated.
        self.lastUpdateTime.store(details.when, ordering: .releasing)

        // Update our state.
        self.mediaState.withLock { existing in
            guard existing == .subscribed else { return }
            existing = .received
        }
    }

    private func startRenderTask(epoch: UInt64) {
        // Check we're valid to start.
        let token = self.renderState.withLock { state -> UInt64? in
            guard state.epoch == epoch,
                  state.token == nil else { return nil }
            state.nextToken &+= 1
            state.token = state.nextToken
            return state.nextToken
        }
        guard let token else { return }

        // Start the simulreceive render.
        let renderWakeup = self.renderWakeup
        let task = Task(priority: .high) { [weak self] in
            defer {
                self?.renderState.withLock { state in
                    guard state.token == token else { return }
                    state.token = nil
                    state.task = nil
                }
            }
            while !Task.isCancelled {
                let duration: TimeInterval
                if let self {
                    guard let next = self.renderStep(token: token, epoch: epoch) else { return }
                    duration = next
                } else {
                    return
                }
                if duration > 0 {
                    await renderWakeup.wait(for: duration)
                }
            }
        }

        let installed = self.renderState.withLock { state in
            guard state.token == token else { return false }
            state.task = task
            return true
        }
        if !installed {
            task.cancel()
        }
    }

    /// Make one simulreceive decision.
    /// - Parameter token: Which render task this is for.
    /// - Parameter epoch: Which lifetime epoch this is for.
    /// - Returns: How long to wait before the next decision.
    private func renderStep(token: UInt64, epoch: UInt64) -> TimeInterval? {
        let owned = self.renderState.withLock { state in
            guard state.token == token,
                  state.epoch == epoch,
                  !Task.isCancelled else { return false }
            self.renderDecisions.enter()
            return true
        }
        guard owned else { return nil }
        defer { self.renderDecisions.leave() }
        guard !self.getHandlers().isEmpty else { return nil }
        do {
            return try self.makeSimulreceiveDecision(at: Ticks.now, epoch: epoch)
        } catch {
            self.logger.warning("Simulreceive failure: \(error.localizedDescription)")
            return nil
        }
    }

    struct SimulreceiveItem: Equatable {
        static func == (lhs: VideoSubscriptionSet.SimulreceiveItem,
                        rhs: VideoSubscriptionSet.SimulreceiveItem) -> Bool {
            lhs.fullTrackName == rhs.fullTrackName
        }
        let fullTrackName: FullTrackName
        let image: AvailableImage
    }

    enum SimulreceiveReason {
        case onlyChoice(item: SimulreceiveItem)
        case highestRes(item: SimulreceiveItem, pristine: Bool)
    }

    internal static func makeSimulreceiveDecision(choices: inout any Collection<SimulreceiveItem>) -> SimulreceiveReason? {
        // Early return.
        guard choices.count > 1 else {
            if let first = choices.first {
                return .onlyChoice(item: first)
            }
            return nil
        }

        // Oldest should be the oldest value that hasn't already been shown.
        let oldest: CMTime = choices.reduce(CMTime.positiveInfinity) { min($0, $1.image.image.presentationTimeStamp) }

        // Filter out any frames that don't match the desired point in time.
        choices = choices.filter { $0.image.image.presentationTimeStamp == oldest }

        // We want the highest non-discontinous frame.
        // If all are non-discontinous, we'll take the highest quality.
        func getWidth(_ item: SimulreceiveItem) -> Int32 {
            item.image.image.formatDescription!.dimensions.width
        }
        let sorted = choices.sorted { getWidth($0) > getWidth($1) }
        let pristine = sorted.filter { !$0.image.discontinous }
        if let pristine = pristine.first {
            return .highestRes(item: pristine, pristine: true)
        } else if let sorted = sorted.first {
            return .highestRes(item: sorted, pristine: false)
        } else {
            return nil
        }
    }

    private static func highestFps(_ handlers: [FullTrackName: VideoHandler]) -> UInt16 {
        handlers.values.reduce(1) { max($0, $1.config.fps) }
    }

    // swiftlint:disable cyclomatic_complexity
    // swiftlint:disable function_body_length
    private func makeSimulreceiveDecision(at: Ticks,
                                          epoch: UInt64) throws -> TimeInterval {
        // Gather up what frames we have to choose from.
        var currentChoices: [SimulreceiveItem] = []
        var handlers: [FullTrackName: VideoHandler] = [:]
        for subscription in self.getHandlers().values {
            guard let subscription = subscription as? VideoSubscription,
                  let handler = subscription.handler.get() else {
                continue
            }
            handlers[handler.fullTrackName] = handler
            handler.lastDecodedImage.withLock { lockedImage in
                guard let available = lockedImage else { return }
                if let lastTime = self.lastImage?.image.presentationTimeStamp,
                   available.image.presentationTimeStamp <= lastTime {
                    // This would be backwards in time, so we'll never use it.
                    lockedImage = nil
                    return
                }
                currentChoices.append(.init(fullTrackName: handler.fullTrackName, image: available))
            }
        }
        for choice in currentChoices {
            self.emit(.simulreceiveCandidate(
                        presentationSeconds: choice.image.image.presentationTimeStamp.seconds),
                      fullTrackName: choice.fullTrackName,
                      handlerGeneration: handlers[choice.fullTrackName]?.generation,
                      epoch: epoch,
                      objectId: nil)
        }

        let currentImages = Dictionary(uniqueKeysWithValues: currentChoices.map {
            ($0.fullTrackName, $0.image)
        })
        let coalescingResult = self.coalescingState.withLock { state -> ([SimulreceiveItem], TimeInterval?) in
            let candidates = state.candidates(from: currentImages).map {
                SimulreceiveItem(fullTrackName: $0.key, image: $0.value)
            }
            guard let oldestPresentationTime = candidates.first?.image.image.presentationTimeStamp else {
                return ([], nil)
            }
            let highestAvailablePristineWidth = candidates
                .filter { !$0.image.discontinous }
                .compactMap { $0.image.image.formatDescription?.dimensions.width }
                .max()
            let expectedHighestWidth = handlers.values.map(\.config.width).max()
            let highestQualityAdvanced = currentChoices.contains { choice in
                choice.image.image.formatDescription?.dimensions.width == expectedHighestWidth &&
                    choice.image.image.presentationTimeStamp > oldestPresentationTime
            }
            let waitDuration = state.waitDuration(
                at: at.hostDate,
                presentationTime: oldestPresentationTime,
                availableQualityCount: candidates.count,
                expectedQualityCount: handlers.count,
                highestAvailablePristineWidth: highestAvailablePristineWidth,
                expectedHighestWidth: expectedHighestWidth,
                highestQualityAdvanced: highestQualityAdvanced)
            return (candidates, waitDuration)
        }
        if let waitDuration = coalescingResult.1 {
            return waitDuration
        }
        let initialChoices = coalescingResult.0

        // Make a decision about which frame to use.
        var choices = initialChoices as any Collection<SimulreceiveItem>
        let decisionTime = self.measurement == nil ? nil : at.hostDate
        let decision = Self.makeSimulreceiveDecision(choices: &choices)

        guard let decision = decision else {
            // Wait for next.
            let duration: TimeInterval
            if let lastNamespace = self.last,
               let handler = handlers[lastNamespace] {
                duration = handler.calculateWaitTime(from: at) ?? (1 / Double(handler.config.fps))
            } else {
                duration = 1 / TimeInterval(Self.highestFps(handlers))
            }
            return duration
        }

        // Consume all images from our shortlist.
        for choice in choices {
            guard let handler = handlers[choice.fullTrackName] else { continue }
            handler.lastDecodedImage.withLock { lockedImage in
                let theirTime = lockedImage?.image.presentationTimeStamp
                let ourTime = choice.image.image.presentationTimeStamp
                if theirTime == ourTime {
                    lockedImage = nil
                }
            }
        }

        var selected: SimulreceiveItem
        switch decision {
        case .highestRes(let out, _):
            selected = out
        case .onlyChoice(let out):
            selected = out
        }

        // If we are changing in quality (resolution or to a discontinuous image)
        // we will only do so after a few hits.
        var wouldStepDown = false
        var wouldStepUp = false
        if let last = self.lastImage {
            let incomingWidth = selected.image.image.formatDescription!.dimensions.width
            if incomingWidth < last.image.formatDescription!.dimensions.width || selected.image.discontinous && !last.discontinous {
                wouldStepDown = true
            } else if incomingWidth > last.image.formatDescription!.dimensions.width {
                wouldStepUp = true
            }
        }

        if wouldStepDown {
            self.qualityMisses += 1
        }

        if wouldStepUp {
            self.qualityHits += 1
        }

        // For step-up, continue rendering current quality during threshold period, if available.
        var continuingCurrentQuality = false
        if wouldStepUp && self.qualityHits < self.config.qualityHitThreshold,
           let lastImage = self.lastImage {
            let lastWidth = lastImage.image.formatDescription!.dimensions.width
            if let currentQualityChoice = initialChoices.first(where: {
                $0.image.image.formatDescription!.dimensions.width == lastWidth
            }) {
                selected = currentQualityChoice
                wouldStepUp = false
                continuingCurrentQuality = true
            }
        }

        let selectedSample = selected.image.image

        // We want to record misses for qualities we have already stepped down from, and pause them
        // if they exceed this count.
        if self.pauseResume {
            //            for pauseCandidateCount in self.pauseMissCounts {
            //                guard let pauseCandidate = self.videoHandlers[pauseCandidateCount.key],
            //                      pauseCandidate.config.width > incomingWidth,
            //                      let callController = self.callController,
            //                      callController.getSubscriptionState(pauseCandidate.namespace) == .ready else {
            //                    continue
            //                }
            //
            //                let newValue = pauseCandidateCount.value + 1
            //                self.logger.warning("Incremented pause count for: \(pauseCandidate.config.width),
            //                                    now: \(newValue)/\(self.pauseMissThreshold)")
            //                if newValue >= self.pauseMissThreshold {
            //                    // Pause this subscription.
            //                    self.logger.warning("Pausing subscription: \(pauseCandidate.config.width)")
            //                    callController.setSubscriptionState(pauseCandidate.namespace, transportMode: .pause)
            //                    self.pauseMissCounts[pauseCandidate.namespace] = 0
            //                } else {
            //                    // Increment the pause miss count.
            //                    self.pauseMissCounts[pauseCandidate.namespace] = newValue
            //                }
            //            }
        }

        guard let handler = handlers[selected.fullTrackName] else {
            throw "Missing video handler for namespace: \(selected.fullTrackName)"
        }

        let stepDown = wouldStepDown && self.qualityMisses < self.qualityMissThreshold
        let stepUp = wouldStepUp && self.qualityHits < self.config.qualityHitThreshold
        let qualitySkip = stepDown || stepUp || continuingCurrentQuality
        if let measurement = self.measurement,
           self.granularMetrics {
            var report: [VideoSubscriptionSet.SimulreceiveChoiceReport] = []
            for choice in choices {
                let isSelectedForDisplay = choice.fullTrackName == selected.fullTrackName
                switch decision {
                case .highestRes(let item, let pristine):
                    if choice.fullTrackName == item.fullTrackName {
                        let reason = "Highest \(pristine ? "Pristine" : "Discontinous")"
                        report.append(.init(item: choice,
                                            selected: true,
                                            reason: reason,
                                            displayed: isSelectedForDisplay && !qualitySkip))
                        continue
                    }
                case .onlyChoice(let item):
                    if choice.fullTrackName == item.fullTrackName {
                        report.append(.init(item: choice,
                                            selected: true,
                                            reason: "Only choice",
                                            displayed: isSelectedForDisplay && !qualitySkip))
                        continue
                    }
                }

                // Note the choice we're actually displaying even if we didn't select.
                if isSelectedForDisplay && continuingCurrentQuality {
                    report.append(.init(item: choice,
                                        selected: false,
                                        reason: "Continuing current quality during step-up threshold",
                                        displayed: true))
                } else {
                    report.append(.init(item: choice, selected: false, reason: "", displayed: false))
                }
            }
            let completedReport = report
            do {
                try measurement.reportSimulreceiveChoice(choices: completedReport,
                                                         timestamp: decisionTime!)
            } catch {
                self.logger.warning("Failed to report simulreceive metrics: \(error.localizedDescription)")
            }
        }

        if qualitySkip {
            self.emit(.simulreceiveSelected(
                        displayed: false,
                        presentationSeconds: selectedSample.presentationTimeStamp.seconds),
                      fullTrackName: selected.fullTrackName,
                      handlerGeneration: handler.generation,
                      epoch: epoch)
            // We only want to change in quality if we've missed a few hits.
            if let duration = handler.calculateWaitTime(from: at) {
                return duration
            }
            if selectedSample.duration.isValid {
                return selectedSample.duration.seconds
            }
            return 1 / TimeInterval(Self.highestFps(handlers))
        }

        // Proceed with rendering this frame.
        self.qualityMisses = 0
        self.qualityHits = 0
        self.pauseMissCounts[handler.fullTrackName] = 0
        self.last = handler.fullTrackName
        self.lastImage = selected.image

        if self.simulreceive == .enable {
            self.emit(.simulreceiveSelected(
                        displayed: true,
                        presentationSeconds: selectedSample.presentationTimeStamp.seconds),
                      fullTrackName: selected.fullTrackName,
                      handlerGeneration: handler.generation,
                      epoch: epoch,
                      objectId: nil)
            // Set to display immediately.
            if selectedSample.sampleAttachments.count > 0 {
                selectedSample.sampleAttachments[0][.displayImmediately] = true
            } else {
                self.logger.warning("Couldn't set display immediately attachment")
            }

            // Enqueue the sample on the main thread.
            let dispatchLabel: String?
            let description = String(describing: handler)
            if description != self.lastSimulreceiveLabel {
                dispatchLabel = description
            } else {
                dispatchLabel = nil
            }

            // If we don't yet have a participant, make one.
            let when = at.hostDate
            Task { @MainActor [weak self] in
                guard let self else { return }

                do {
                    let e2eLatency: TimeInterval?
                    if self.config.calculateLatency {
                        let now = Date.now
                        let presentationTime = selectedSample.presentationTimeStamp.seconds
                        let presentationDate = Date(timeIntervalSince1970: presentationTime)
                        let age = now.timeIntervalSince(presentationDate)
                        if self.granularMetrics,
                           let measurement = measurement {
                            measurement.age(age, timestamp: now)
                        }
                        e2eLatency = age
                    } else {
                        e2eLatency = nil
                    }
                    let transform = handler.orientation?.toTransform(handler.verticalMirror)
                    let rendered: VideoDisplayEnqueueTiming? = try self.renderState.withLock { state in
                        guard let registration = try self.getOrCreateParticipant(state: &state,
                                                                                 epoch: epoch) else {
                            return nil
                        }
                        guard let timing = try registration.withParticipant({ participant in
                            if let dispatchLabel {
                                participant.label = dispatchLabel
                            }
                            return try participant.enqueue(selectedSample,
                                                           transform: transform,
                                                           when: when,
                                                           endToEndLatency: e2eLatency)
                        }) else { return nil }
                        self.mediaState.withLock { $0 = .rendered }
                        return timing
                    }
                    guard let timing = rendered else { return }
                    if self.granularMetrics,
                       let measurement = self.measurement {
                        measurement.displayEnqueueTiming(timing, timestamp: Date.now)
                    }
                    self.emit(.displayEnqueueTiming(timing),
                              fullTrackName: selected.fullTrackName,
                              handlerGeneration: handler.generation,
                              epoch: epoch)
                    self.emit(.displayEnqueued(
                                presentationSeconds: selectedSample.presentationTimeStamp.seconds),
                              fullTrackName: selected.fullTrackName,
                              handlerGeneration: handler.generation,
                              epoch: epoch)
                    self.displayCallbacks.fire()
                } catch {
                    self.logger.warning("Could not enqueue sample: \(error)")
                    self.emit(.displayError(error.localizedDescription),
                              fullTrackName: selected.fullTrackName,
                              handlerGeneration: handler.generation,
                              epoch: epoch)
                }
            }
        } else if self.simulreceive == .visualizeOnly {
            let fullTrackName = handler.fullTrackName
            if fullTrackName != self.lastHighlight {
                self.logger.debug("Updating highlight to: \(selectedSample.formatDescription!.dimensions.width)")
                self.lastHighlight = fullTrackName
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.renderState.withLock { state in
                        guard state.epoch == epoch else { return }
                        self.participants.forEachParticipant { participant in
                            participant.highlight = participant.id == "\(fullTrackName)"
                        }
                    }
                }
            }
        }

        // Wait until we have expect to have the next frame available.
        if let duration = handler.calculateWaitTime(from: at) {
            return duration
        }
        if selectedSample.duration.isValid {
            return selectedSample.duration.seconds
        }
        return 1 / TimeInterval(Self.highestFps(handlers))
    }
    // swiftlint:enable cyclomatic_complexity
    // swiftlint:enable function_body_length

    override func pause() {
        self.mediaState.withLock { $0 = .subscribed }
        super.pause()
    }

    // MARK: DisplayNotification implementation.

    private let displayCallbacks = Mutex<DisplayCallbacks>(.init())
    private let mediaState = Mutex<MediaState>(.subscribed)

    func registerDisplayCallback(_ callback: @escaping DisplayCallback) {
        self.displayCallbacks.store(callback)
    }

    func unregisterDisplayCallback(_ token: Int) {
        self.displayCallbacks.remove(token)
    }

    func getMediaState() -> MediaState {
        self.mediaState.get()
    }

    func fireDisplayCallbacks() {
        #if DEBUG
        self.mediaState.withLock { $0 = .rendered }
        #else
        assert(self.mediaState.get() == .rendered)
        #endif
        self.displayCallbacks.fire()
    }
}

extension VideoSubscriptionSet {
    func decodedImageAvailable(subscriptionIdentity: UUID,
                               fullTrackName: FullTrackName,
                               handlerGeneration: UInt64,
                               decodedSpread: TimeInterval?) {
        self.membership.withLock { _ in
            guard let subscription = self.getHandlers()[fullTrackName] as? VideoSubscription,
                  subscription.identity == subscriptionIdentity,
                  subscription.handler.get()?.generation == handlerGeneration else { return }
            if let decodedSpread {
                self.coalescingState.withLock { $0.record(decodedSpread: decodedSpread) }
            }
            let epoch = self.renderState.withLock { $0.epoch }
            self.startRenderTask(epoch: epoch)
            self.renderWakeup.signal()
        }
    }
}
