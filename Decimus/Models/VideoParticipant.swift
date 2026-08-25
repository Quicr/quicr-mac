// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import QuartzCore
import CoreMedia
import Synchronization

enum ParticipantError: Error {
    case alreadyExists
}

/// Represents a visible video display.
@Observable
@MainActor
class VideoParticipant: Identifiable {
    /// The identifier for this participant (either a namespace, or a source ID for an aggregate).
    let id: SourceIDType
    /// The participant ID of this participant.
    let participantId: ParticipantId
    /// The SwiftUI view for video display.
    let view = VideoView()
    /// The label to display under the video.
    var label: String
    /// True if this video should be highlighted.
    var highlight: Bool
    /// True if this video should be displayed.
    var display = false
    /// Last time a frame was enqueued.
    var lastEnqueueTime: Date?
    private let logger = DecimusLogger(VideoParticipant.self)

    // Active speaker statistics.
    private let activeSpeakerStats: ActiveSpeakerStats?
    private let startDate: Date
    private let subscribeDate: Date
    private(set) var fromDetected: TimeInterval?
    private(set) var fromSet: TimeInterval?
    private(set) var joinToFirstFrame: TimeInterval?
    private(set) var subscribeToFirstFrame: TimeInterval?

    // End to end latency / age statistics.
    @Observable
    class LatencyRecord {
        let slidingWindow: SlidingTimeWindow<TimeInterval>
        private(set) var average: TimeInterval?

        init(_ length: TimeInterval) {
            self.slidingWindow = SlidingTimeWindow(length: length)
        }

        func calc(from: Date) {
            let window = self.slidingWindow.get(from: .now)
            if window.count > 0 {
                self.average = window.reduce(0, +) / TimeInterval(window.count)
            }
        }
    }

    @Observable
    class Latencies {
        let display: LatencyRecord
        let receive: LatencyRecord
        let traversal: LatencyRecord

        init(_ length: TimeInterval) {
            self.display = .init(length)
            self.receive = .init(length)
            self.traversal = .init(length)
        }

        func calc(from: Date) {
            self.display.calc(from: from)
            self.receive.calc(from: from)
            self.traversal.calc(from: from)
        }
    }
    let latencies: Latencies?
    private nonisolated let averagingTask: Task<(), Never>?

    /// Configuration for the participant view.
    struct Config {
        /// Whether to calculate end-to-end latency.
        let calculateLatency: Bool
        /// The time interval for the sliding window used to calculate end-to-end latency.
        let slidingWindowTime: TimeInterval
    }

    private let switchLatencyMeasurement: SwitchLatencyMeasurement?

    /// Create a new participant for the given identifier.
    /// - Parameter id: Namespace or source ID.
    /// - Parameter startDate: Join date of the call, for statistics.
    /// - Parameter subscribeDate: Subscribe date of the call, for statistics.
    /// - Parameter participantId: The participant ID of this participant.
    /// - Parameter activeSpeakerStats: Stats/metrics object.
    /// - Parameter config: The configuration.
    /// - Parameter switchLatencyMeasurement: Metrics for speaker switching.
    init(id: SourceIDType,
         startDate: Date,
         subscribeDate: Date,
         participantId: ParticipantId,
         activeSpeakerStats: ActiveSpeakerStats?,
         config: Config,
         switchLatencyMeasurement: SwitchLatencyMeasurement? = nil) {
        self.id = id
        self.label = id
        self.highlight = false
        self.startDate = startDate
        self.subscribeDate = subscribeDate
        self.participantId = participantId
        self.activeSpeakerStats = activeSpeakerStats
        self.switchLatencyMeasurement = switchLatencyMeasurement
        if config.calculateLatency {
            let latencies = Latencies(config.slidingWindowTime)
            self.latencies = latencies
            self.averagingTask = Task(priority: .utility) {
                while !Task.isCancelled {
                    latencies.calc(from: .now)
                    try? await Task.sleep(for: .seconds(config.slidingWindowTime))
                }
            }
        } else {
            self.latencies = nil
            self.averagingTask = nil
        }
    }

    func received(_ details: ObjectReceived) {
        if let timestamp = details.timestamp,
           let receive = self.latencies?.receive {
            let presentationDate = Date(timeIntervalSince1970: timestamp)
            receive.slidingWindow.add(timestamp: details.when.hostDate,
                                      value: details.when.hostDate.timeIntervalSince(presentationDate))
        }

        if let publishTimestamp = details.publishTimestamp,
           let traversal = self.latencies?.traversal {
            traversal.slidingWindow.add(timestamp: details.when.hostDate,
                                        value: details.when.hostDate.timeIntervalSince(publishTimestamp))
        }

        guard let stats = self.activeSpeakerStats else { return }
        let participantId = self.participantId
        Task { @MainActor in
            if details.usable {
                await stats.dataReceived(participantId, when: details.when.hostDate)
            } else {
                await stats.dataDropped(participantId, when: details.when.hostDate)
            }
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer,
                 transform: CATransform3D?,
                 when: Date,
                 endToEndLatency: TimeInterval?,
                 switchContext: SwitchContext? = nil,
                 renderTime: Date? = nil) throws {
        // Stats.
        if let stats = self.activeSpeakerStats {
            let participantId = self.participantId
            Task { @MainActor [weak self] in
                guard let record = try? await stats.imageEnqueued(participantId, when: when) else {
                    self?.logger.warning("[\(participantId)] Failed to record enqueue image")
                    return
                }
                guard let self else { return }
                if let detected = record.detected {
                    self.fromDetected = record.enqueued.timeIntervalSince(detected)
                }
                if let set = record.set {
                    self.fromSet = record.enqueued.timeIntervalSince(set)
                }
            }
        }
        if self.joinToFirstFrame == nil {
            self.joinToFirstFrame = when.timeIntervalSince(self.startDate)
            self.subscribeToFirstFrame = when.timeIntervalSince(self.subscribeDate)
        }

        // If we have a switch, emit the corresponding metrics.
        if let switchContext,
           let renderTime,
           let measurement = self.switchLatencyMeasurement {
            let participantStr = "\(self.participantId.participantId)"
            measurement.record(context: switchContext,
                               renderTime: renderTime,
                               participant: participantStr)
        }

        if let endToEndLatency,
           let latencies = self.latencies {
            latencies.display.slidingWindow.add(timestamp: when, value: endToEndLatency)
        }

        // Enqueue the frame.
        self.lastEnqueueTime = when
        self.display = true
        try self.view.enqueue(sampleBuffer, transform: transform)
    }

    deinit {
        self.averagingTask?.cancel()
        self.logger.debug("[\(self.id)] Deinit")
    }
}

/// Owns one participant's registration in the visible participant collection.
@MainActor
final class VideoParticipantRegistration {
    let participant: VideoParticipant

    private let active = Mutex(true)
    private weak var participants: VideoParticipants?

    fileprivate init(participant: VideoParticipant, participants: VideoParticipants) {
        self.participant = participant
        self.participants = participants
    }

    deinit {
        guard let participants = self.participants else { return }
        let id = self.participant.id
        Task { @MainActor in
            participants.removeReleased(id)
        }
    }

    var isActive: Bool {
        self.active.get()
    }

    /// Prevent new work from using the participant.
    nonisolated func invalidate() {
        self.active.withLock { $0 = false }
    }

    /// Perform work only while this registration remains active.
    func withParticipant<Result>(_ body: (VideoParticipant) throws -> Result) rethrows -> Result? {
        try self.active.withLock { active in
            guard active else { return nil }
            return try body(self.participant)
        }
    }

    /// Remove the participant from the collection. Safe to call repeatedly.
    func remove() {
        self.invalidate()
        self.participants?.remove(self)
    }
}

/// Holder for all video participants.
@Observable
@MainActor
class VideoParticipants {
    class Weak<T: AnyObject>: Identifiable {
        weak var value: T?
        init(_ value: T) {
            self.value = value
        }
    }

    private class Entry {
        let participant: Weak<VideoParticipant>
        let registration: Weak<VideoParticipantRegistration>

        init(participant: VideoParticipant,
             registration: VideoParticipantRegistration) {
            self.participant = .init(participant)
            self.registration = .init(registration)
        }
    }

    private let logger = DecimusLogger(VideoParticipants.self)

    /// How long without a frame before hiding a participant.
    var stalenessThreshold: TimeInterval = 0.3

    /// Maximum number of participants to display, nil for unlimited.
    var maxDisplayCount: Int?

    /// All tracked participants by identifier.
    private var weakParticipants: [SourceIDType: Entry] = [:]
    var participants: [Weak<VideoParticipant>] {
        self.weakParticipants.values.map(\.participant)
    }
    private var stalenessTask: Task<Void, Never>?

    /// Perform work on participants whose registrations are still active.
    func forEachParticipant(_ body: (VideoParticipant) -> Void) {
        for entry in self.weakParticipants.values {
            entry.registration.value?.withParticipant(body)
        }
    }

    /// Remove stale participants if we can replace them with live ones.
    func startStalenessChecks() {
        guard self.stalenessTask == nil else { return }
        self.stalenessTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.stalenessThreshold / 2))
                let now = Date.now
                let registrations = self.weakParticipants.values.compactMap(\.registration.value)
                    .filter(\.isActive)
                let displayed = registrations.filter { $0.participant.display }
                let freshCount = displayed.filter { registration in
                    registration.participant.lastEnqueueTime.map {
                        now.timeIntervalSince($0) <= self.stalenessThreshold
                    } ?? false
                }.count
                let target = self.maxDisplayCount ?? displayed.count
                guard freshCount >= target else { continue }
                for registration in displayed {
                    registration.withParticipant { participant in
                        if let last = participant.lastEnqueueTime,
                           now.timeIntervalSince(last) > self.stalenessThreshold {
                            participant.display = false
                        }
                    }
                }
            }
        }
    }

    /// Stop staleness checking.
    func stopStalenessChecks() {
        self.stalenessTask?.cancel()
        self.stalenessTask = nil
    }

    /// Register a participant.
    /// - Parameter videoParticipant: The participant to add.
    /// - Returns: The registration that owns the participant's collection membership.
    /// - Throws: ``ParticipantError.alreadyExists`` if the participant has already been added.
    func register(_ videoParticipant: VideoParticipant) throws -> VideoParticipantRegistration {
        if let existing = self.weakParticipants[videoParticipant.id]?.registration.value,
           existing.isActive {
            throw ParticipantError.alreadyExists
        }
        let registration = VideoParticipantRegistration(participant: videoParticipant,
                                                        participants: self)
        self.weakParticipants[videoParticipant.id] = .init(participant: videoParticipant,
                                                           registration: registration)
        self.logger.debug("[\(videoParticipant.id)] Added participant")
        return registration
    }

    /// Remove a participant if it is still the registered instance for its identifier.
    fileprivate func remove(_ registration: VideoParticipantRegistration) {
        let participant = registration.participant
        guard self.weakParticipants[participant.id]?.registration.value === registration else { return }
        self.weakParticipants.removeValue(forKey: participant.id)
        self.logger.debug("[\(participant.id)] Removed participant")
    }

    /// Remove a participant whose registration has been released, unless it has already been replaced.
    fileprivate func removeReleased(_ identifier: SourceIDType) {
        guard let entry = self.weakParticipants[identifier],
              entry.registration.value == nil else { return }
        self.weakParticipants.removeValue(forKey: identifier)
        self.logger.debug("[\(identifier)] Removed released participant")
    }
}
