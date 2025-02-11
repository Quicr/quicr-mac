// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import os
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

// swiftlint:disable type_body_length
class VideoSubscriptionSet: ObservableSubscriptionSet {
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
    private var last: FullTrackName?
    private var lastImage: AvailableImage?
    private let qualityMissThreshold: Int
    private var cleanupTask: Task<(), Never>?
    private var lastUpdateTime = Date.now
    private var handlerLock = OSAllocatedUnfairLock()
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
    private var timestampTimeDiff: TimeInterval?
    private var liveSubscriptions: Set<FullTrackName> = []
    private let liveSubscriptionsLock = OSAllocatedUnfairLock()
    private let subscribeDate: Date
    private var participant: VideoParticipant?
    private let participantLock = OSAllocatedUnfairLock()
    private let joinDate: Date

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
         cleanupTime: TimeInterval) throws {
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
        self.cleanupTimer = cleanupTime

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

        // Make all the video subscriptions upfront.
        self.profiles = createdProfiles

        // Base.
        super.init(sourceId: subscription.sourceID, participantId: subscription.participantId)

        // Make task for cleaning up simulreceive rendering.
        if simulreceive == .enable {
            self.cleanupTask = .init(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    let time: TimeInterval
                    if let self = self {
                        time = self.cleanupTimer
                        if Date.now.timeIntervalSince(self.lastUpdateTime) >= self.cleanupTimer {
                            self.participantLock.withLock { self.participant = nil }
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

    override func addHandler(_ handler: QSubscribeTrackHandlerObjC) throws {
        guard let handler = handler as? VideoSubscription else {
            throw "Handler MUST be VideoSubscription"
        }
        try super.addHandler(handler)
    }

    override func removeHandler(_ ftn: FullTrackName) -> Subscription? {
        let result = super.removeHandler(ftn)
        if self.simulreceive == .enable,
           self.getHandlers().isEmpty {
            Self.logger.debug("Destroying simulreceive render as no live subscriptions")
            self.renderTask?.cancel()
            self.participantLock.withLock { self.participant = nil }
        }
        return result
    }

    /// Inform the set that a video frame from a managed subscription arrived.
    /// - Parameter timestamp: Media timestamp of the arrived frame.
    /// - Parameter when: The local datetime this happened.
    public func receivedObject(_ ftn: FullTrackName, timestamp: TimeInterval, when: Date, cached: Bool) {
        // Set the timestamp diff from the first recveived live object.
        if !cached {
            if self.timestampTimeDiff == nil {
                self.timestampTimeDiff = when.timeIntervalSince1970 - timestamp
            }

            // Set this diff for all handlers, if not already.
            if let diff = self.timestampTimeDiff {
                let subscriptions = self.getHandlers()
                for (_, sub) in subscriptions {
                    let sub = sub as! VideoSubscription // swiftlint:disable:this force_cast
                    sub.handlerLock.withLock {
                        guard let handler = sub.handler else { return }
                        handler.setTimeDiff(diff: diff)
                    }
                }
            }
        }

        // Calculate switching set arrival variance.
        _ = self.variances.calculateSetVariance(timestamp: timestamp, now: when)
        if self.granularMetrics,
           let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.measurement.reportTimestamp(namespace: self.subscription.sourceID,
                                                              timestamp: timestamp,
                                                              when: when,
                                                              cached: cached)
            }
        }

        // If we're responsible for rendering.
        if self.simulreceive != .none {
            // Start the render task.
            if self.renderTask == nil || self.renderTask!.isCancelled {
                self.startRenderTask()
            }
        }

        // Record the last time this updated.
        self.lastUpdateTime = when
    }

    private func startRenderTask() {
        self.renderTask = .init(priority: .high) { [weak self] in
            while !Task.isCancelled {
                let duration: TimeInterval
                if let self = self {
                    let now = Date.now
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

    // Caller must lock handlerLock.
    // swiftlint:disable cyclomatic_complexity
    // swiftlint:disable function_body_length
    private func makeSimulreceiveDecision(at: Date) throws -> TimeInterval {
        // Gather up what frames we have to choose from.
        var initialChoices: [SimulreceiveItem] = []
        let subscriptions = self.getHandlers().mapValues { $0 as! VideoSubscription } // swiftlint:disable:this force_cast
        for subscription in subscriptions {
            guard let handler = subscription.value.handler else {
                continue
            }
            handler.lastDecodedImageLock.lock()
            defer { handler.lastDecodedImageLock.unlock() }
            if let available = handler.lastDecodedImage {
                if let lastTime = self.lastImage?.image.presentationTimeStamp,
                   available.image.presentationTimeStamp <= lastTime {
                    // This would be backwards in time, so we'll never use it.
                    handler.lastDecodedImage = nil
                    continue
                }
                initialChoices.append(.init(fullTrackName: handler.fullTrackName, image: available))
            }
        }

        // Make a decision about which frame to use.
        var choices = initialChoices as any Collection<SimulreceiveItem>
        let decisionTime = self.measurement == nil ? nil : at
        let decision = Self.makeSimulreceiveDecision(choices: &choices)

        guard let decision = decision else {
            // Wait for next.
            let duration: TimeInterval
            if let lastNamespace = self.last,
               let handler = subscriptions[lastNamespace]?.handler {
                duration = handler.calculateWaitTime(from: at) ?? (1 / Double(handler.config.fps))
            } else {
                var highestFps: UInt16 = 1
                for subscription in subscriptions {
                    guard let handler = subscription.value.handler else {
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
            let handler = subscriptions[choice.fullTrackName]!.handler!
            handler.lastDecodedImageLock.withLock {
                let theirTime = handler.lastDecodedImage?.image.presentationTimeStamp
                let ourTime = choice.image.image.presentationTimeStamp
                if theirTime == ourTime {
                    handler.lastDecodedImage = nil
                }
            }
        }

        let selected: SimulreceiveItem
        switch decision {
        case .highestRes(let out, _):
            selected = out
        case .onlyChoice(let out):
            selected = out
        }
        let selectedSample = selected.image.image

        // If we are going down in quality (resolution or to a discontinous image)
        // we will only do so after a few hits.
        let incomingWidth = selectedSample.formatDescription!.dimensions.width
        var wouldStepDown = false
        if let last = self.lastImage,
           incomingWidth < last.image.formatDescription!.dimensions.width || selected.image.discontinous && !last.discontinous {
            wouldStepDown = true
        }

        if wouldStepDown {
            self.qualityMisses += 1
        }

        // We want to record misses for qualities we have already stepped down from, and pause them
        // if they exceed this count.
        if self.pauseResume {
            fatalError("Not supported")
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
        guard let handler = subscription.handler else {
            throw "Missing video hanler for namespace: \(selected.fullTrackName)"
        }

        let qualitySkip = wouldStepDown && self.qualityMisses < self.qualityMissThreshold
        if let measurement = self.measurement,
           self.granularMetrics {
            var report: [VideoSubscriptionSet.SimulreceiveChoiceReport] = []
            for choice in choices {
                switch decision {
                case .highestRes(let item, let pristine):
                    if choice.fullTrackName == item.fullTrackName {
                        assert(choice.fullTrackName == selected.fullTrackName)
                        report.append(.init(item: choice,
                                            selected: true,
                                            reason: "Highest \(pristine ? "Pristine" : "Discontinous")",
                                            displayed: !qualitySkip))
                        continue
                    }
                case .onlyChoice(let item):
                    if choice.fullTrackName == item.fullTrackName {
                        assert(choice.fullTrackName == selected.fullTrackName)
                        report.append(.init(item: choice,
                                            selected: true,
                                            reason: "Only choice",
                                            displayed: !qualitySkip))
                    }
                    continue
                }
                report.append(.init(item: choice, selected: false, reason: "", displayed: false))
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
            // We only want to step down in quality if we've missed a few hits.
            if let duration = handler.calculateWaitTime(from: at) {
                return duration
            }
            if selectedSample.duration.isValid {
                return selectedSample.duration.seconds
            }
            var highestFps: UInt16 = 1
            for subscription in subscriptions {
                guard let handler = subscription.value.handler else {
                    continue
                }
                highestFps = max(highestFps, handler.config.fps)
            }
            return 1 / TimeInterval(highestFps)
        }

        // Proceed with rendering this frame.
        self.qualityMisses = 0
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
            Task {
                await MainActor.run {
                    self.participantLock.lock()
                    let participant: VideoParticipant
                    if let existing = self.participant {
                        participant = existing
                    } else {
                        do {
                            participant = try .init(id: self.sourceId,
                                                    startDate: self.joinDate,
                                                    subscribeDate: self.subscribeDate,
                                                    videoParticipants: self.participants)
                        } catch {
                            self.participantLock.unlock()
                            return
                        }
                        self.participant = participant
                    }
                    self.participantLock.unlock()
                    if let dispatchLabel = dispatchLabel {
                        participant.label = dispatchLabel
                    }
                    do {
                        let transform = handler.orientation?.toTransform(handler.verticalMirror)
                        try participant.view.enqueue(selectedSample,
                                                     transform: transform)
                    } catch {
                        Self.logger.error("Could not enqueue sample: \(error)")
                    }
                }
            }
        } else if self.simulreceive == .visualizeOnly {
            let fullTrackName = handler.fullTrackName
            if fullTrackName != self.lastHighlight {
                Self.logger.debug("Updating highlight to: \(selectedSample.formatDescription!.dimensions.width)")
                self.lastHighlight = fullTrackName
                Task {
                    await MainActor.run {
                        for participant in self.participants.participants {
                            guard let participant = participant.value else { continue }
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
        var highestFps: UInt16 = 1
        for subscription in subscriptions {
            guard let handler = subscription.value.handler else {
                continue
            }
            highestFps = max(highestFps, handler.config.fps)
        }
        return 1 / TimeInterval(highestFps)
    }
    // swiftlint:enable cyclomatic_complexity
    // swiftlint:enable function_body_length
}
// swiftlint:enable type_body_length
