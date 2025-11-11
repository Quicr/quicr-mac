// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization
import CoreMedia

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

class VideoSubscriptionSet: ObservableSubscriptionSet, DisplayNotification {
    private static let logger = DecimusLogger(VideoSubscriptionSet.self)

    private let subscription: ManifestSubscription
    private let participants: VideoParticipants
    private let submitter: MetricsSubmitter?
    private let videoBehaviour: VideoBehaviour
    private let reliable: Bool
    private let granularMetrics: Bool
    private let jitterBufferConfig: JitterBuffer.Config
    private var renderTask: Task<(), Never>?
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
    private let measurement: MeasurementRegistration<VideoSubscriptionMeasurement>?
    private let variances: VarianceCalculator
    let decodedVariances: VarianceCalculator
    private let subscribeDate: Date
    private let participant = Mutex<VideoParticipant?>(nil)
    private let joinDate: Date
    private let activeSpeakerStats: ActiveSpeakerStats?
    private var timeAligner: TimeAligner?
    private let lastTimestampReceived = Atomic(Int64.zero)
    private let config: Config

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
         reliable: Bool,
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
         config: Config) throws {
        if simulreceive != .none && jitterBufferConfig.mode == .layer {
            throw "Simulreceive and layer are not compatible"
        }

        self.subscription = subscription
        self.participants = participants
        self.submitter = metricsSubmitter
        if let submitter = metricsSubmitter {
            let measurement = VideoSubscriptionMeasurement(source: self.subscription.sourceID)
            self.measurement = .init(measurement: measurement, submitter: submitter)
        } else {
            self.measurement = nil
        }
        self.videoBehaviour = videoBehaviour
        self.reliable = reliable
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
                        let lastUpdate = self.lastUpdateTime.load(ordering: .acquiring)
                        if Ticks.now.timeIntervalSince(lastUpdate) >= self.cleanupTimer {
                            self.participant.clear()
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

        Self.logger.info("Subscribed to video stream")
    }

    deinit {
        self.cleanupTask?.cancel()
        Self.logger.debug("Deinit")
    }

    override func removeHandler(_ ftn: FullTrackName) -> Subscription? {
        let result = super.removeHandler(ftn)
        if self.simulreceive == .enable,
           self.getHandlers().isEmpty {
            Self.logger.debug("Destroying simulreceive render as no live subscriptions")
            self.renderTask?.cancel()
            self.participant.clear()
        }
        return result
    }

    /// Inform the set that a video frame from a managed subscription arrived.
    /// - Parameter ftn: The full track name of the subscription this object came from.
    /// - Parameter timestamp: Media timestamp of the arrived frame, if usable.
    /// - Parameter when: The local datetime this happened.
    /// - Parameter cached: True if this object is cached.
    /// - Parameter usable: True if this object should be used.
    public func receivedObject(_ ftn: FullTrackName, details: ObjectReceived) {
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

            Task {
                try await MainActor.run {
                    let participant = try self.participant.withLock { locked in
                        guard let existing = locked else {
                            let created = try VideoParticipant(id: self.sourceId,
                                                               startDate: self.joinDate,
                                                               subscribeDate: self.subscribeDate,
                                                               videoParticipants: self.participants,
                                                               participantId: self.participantId,
                                                               activeSpeakerStats: self.activeSpeakerStats,
                                                               config: self.config.getVideoParticipantConfig(self))
                            locked = created
                            return created
                        }
                        return existing
                    }
                    if report {
                        participant.received(details)
                    }
                }
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
            // Start the render task.
            if self.renderTask == nil || self.renderTask!.isCancelled {
                self.startRenderTask()
            }
        }

        // Record the last time this updated.
        self.lastUpdateTime.store(details.when, ordering: .releasing)

        // Update our state.
        self.mediaState.withLock { existing in
            guard existing == .subscribed else { return }
            existing = .received
        }
    }

    private func startRenderTask() {
        self.renderTask = .init(priority: .high) { [weak self] in
            while !Task.isCancelled {
                let duration: TimeInterval
                if let self = self {
                    let now = Ticks.now
                    if self.getHandlers().isEmpty {
                        self.renderTask?.cancel()
                        duration = TimeInterval.nan
                    } else {
                        do {
                            duration = try self.makeSimulreceiveDecision(at: now)
                        } catch {
                            Self.logger.error("Simulreceive failure: \(error.localizedDescription)")
                            self.renderTask?.cancel()
                            duration = TimeInterval.nan
                        }
                    }
                } else {
                    return
                }
                if duration > 0 {
                    try? await Task.sleep(for: .seconds(duration))
                }
            }
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

    // swiftlint:disable cyclomatic_complexity
    // swiftlint:disable function_body_length
    private func makeSimulreceiveDecision(at: Ticks) throws -> TimeInterval {
        // Gather up what frames we have to choose from.
        var initialChoices: [SimulreceiveItem] = []
        let subscriptions = self.getHandlers().mapValues { $0 as! VideoSubscription } // swiftlint:disable:this force_cast
        for subscription in subscriptions {
            guard let handler = subscription.value.handler.get() else {
                continue
            }
            handler.lastDecodedImage.withLock { lockedImage in
                guard let available = lockedImage else { return }
                if let lastTime = self.lastImage?.image.presentationTimeStamp,
                   available.image.presentationTimeStamp <= lastTime {
                    // This would be backwards in time, so we'll never use it.
                    lockedImage = nil
                    return
                }
                initialChoices.append(.init(fullTrackName: handler.fullTrackName, image: available))
            }
        }

        // Make a decision about which frame to use.
        var choices = initialChoices as any Collection<SimulreceiveItem>
        let decisionTime = self.measurement == nil ? nil : at.hostDate
        let decision = Self.makeSimulreceiveDecision(choices: &choices)

        guard let decision = decision else {
            // Wait for next.
            let duration: TimeInterval
            if let lastNamespace = self.last,
               let handler = subscriptions[lastNamespace]?.handler.get() {
                duration = handler.calculateWaitTime(from: at) ?? (1 / Double(handler.config.fps))
            } else {
                var highestFps: UInt16 = 1
                for subscription in subscriptions {
                    guard let handler = subscription.value.handler.get() else {
                        continue
                    }
                    highestFps = max(highestFps, handler.config.fps)
                }
                duration = TimeInterval(1 / highestFps)
            }
            return duration
        }

        // Consume all images from our shortlist.
        for choice in choices {
            let handler = subscriptions[choice.fullTrackName]!.handler.get()!
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
            //                Self.logger.warning("Incremented pause count for: \(pauseCandidate.config.width), now: \(newValue)/\(self.pauseMissThreshold)")
            //                if newValue >= self.pauseMissThreshold {
            //                    // Pause this subscription.
            //                    Self.logger.warning("Pausing subscription: \(pauseCandidate.config.width)")
            //                    callController.setSubscriptionState(pauseCandidate.namespace, transportMode: .pause)
            //                    self.pauseMissCounts[pauseCandidate.namespace] = 0
            //                } else {
            //                    // Increment the pause miss count.
            //                    self.pauseMissCounts[pauseCandidate.namespace] = newValue
            //                }
            //            }
        }

        guard let subscription = subscriptions[selected.fullTrackName] else {
            throw "Missing expected subscription for namespace: \(selected.fullTrackName)"
        }
        guard let handler = subscription.handler.get() else {
            throw "Missing video hanler for namespace: \(selected.fullTrackName)"
        }

        let qualitySkip = (wouldStepDown && self.qualityMisses < self.qualityMissThreshold) || (wouldStepUp && self.qualityHits < self.config.qualityHitThreshold) || continuingCurrentQuality
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
            Task(priority: .utility) {
                do {
                    try await measurement.measurement.reportSimulreceiveChoice(choices: completedReport,
                                                                               timestamp: decisionTime!)
                } catch {
                    Self.logger.warning("Failed to report simulreceive metrics: \(error.localizedDescription)")
                }
            }
        }

        if qualitySkip {
            // We only want to change in quality if we've missed a few hits.
            if let duration = handler.calculateWaitTime(from: at) {
                return duration
            }
            if selectedSample.duration.isValid {
                return selectedSample.duration.seconds
            }
            var highestFps: UInt16 = 1
            for subscription in subscriptions {
                guard let handler = subscription.value.handler.get() else {
                    continue
                }
                highestFps = max(highestFps, handler.config.fps)
            }
            return 1 / TimeInterval(highestFps)
        }

        // Proceed with rendering this frame.
        self.qualityMisses = 0
        self.qualityHits = 0
        self.pauseMissCounts[handler.fullTrackName] = 0
        self.last = handler.fullTrackName
        self.lastImage = selected.image

        if self.simulreceive == .enable {
            // Set to display immediately.
            if selectedSample.sampleAttachments.count > 0 {
                selectedSample.sampleAttachments[0][.displayImmediately] = true
            } else {
                Self.logger.warning("Couldn't set display immediately attachment")
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
                guard let self = self else { return }
                let participant: VideoParticipant
                do {
                    participant = try self.participant.withLock { lockedParticipant in
                        if let existing = lockedParticipant {
                            return existing
                        }
                        let created = try VideoParticipant(id: self.sourceId,
                                                           startDate: self.joinDate,
                                                           subscribeDate: self.subscribeDate,
                                                           videoParticipants: self.participants,
                                                           participantId: self.participantId,
                                                           activeSpeakerStats: self.activeSpeakerStats,
                                                           config: self.config.getVideoParticipantConfig(self))
                        lockedParticipant = created
                        return created
                    }
                } catch {
                    Self.logger.warning("Failed to create participant: \(error.localizedDescription)")
                    return
                }

                if let dispatchLabel = dispatchLabel {
                    participant.label = dispatchLabel
                }
                do {
                    let e2eLatency: TimeInterval?
                    if self.config.calculateLatency {
                        let now = Date.now
                        let presentationTime = selectedSample.presentationTimeStamp.seconds
                        let presentationDate = Date(timeIntervalSince1970: presentationTime)
                        let age = now.timeIntervalSince(presentationDate)
                        if self.granularMetrics,
                           let measurement = measurement?.measurement {
                            Task(priority: .utility) {
                                await measurement.age(age, timestamp: now)
                            }
                        }
                        e2eLatency = age
                    } else {
                        e2eLatency = nil
                    }
                    let transform = handler.orientation?.toTransform(handler.verticalMirror)
                    try participant.enqueue(selectedSample,
                                            transform: transform,
                                            when: when,
                                            endToEndLatency: e2eLatency)
                    self.mediaState.withLock { existing in
                        assert(existing != .subscribed)
                        existing = .rendered
                    }
                    self.displayCallbacks.fire()
                } catch {
                    Self.logger.error("Could not enqueue sample: \(error)")
                }
            }
        } else if self.simulreceive == .visualizeOnly {
            let fullTrackName = handler.fullTrackName
            if fullTrackName != self.lastHighlight {
                Self.logger.debug("Updating highlight to: \(selectedSample.formatDescription!.dimensions.width)")
                self.lastHighlight = fullTrackName
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    for participant in self.participants.participants {
                        guard let participant = participant.value else { continue }
                        participant.highlight = participant.id == "\(fullTrackName)"
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
        var highestFps: UInt16 = 1
        for subscription in subscriptions {
            guard let handler = subscription.value.handler.get() else {
                continue
            }
            highestFps = max(highestFps, handler.config.fps)
        }
        return 1 / TimeInterval(highestFps)
    }
    // swiftlint:enable cyclomatic_complexity
    // swiftlint:enable function_body_length

    // MARK: DisplayNotification implementation.

    private let displayCallbacks = Mutex<DisplayCallbacks>(.init())
    private let mediaState = Mutex<MediaState>(.subscribed)

    func registerDisplayCallback(_ callback: @escaping DisplayCallback) -> Int {
        return self.displayCallbacks.store(callback)
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
