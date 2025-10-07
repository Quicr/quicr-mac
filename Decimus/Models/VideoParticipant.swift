// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import QuartzCore
import CoreMedia

enum ParticipantError: Error {
    case alreadyExists
    case notFound
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
    private let videoParticipants: VideoParticipants
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
    private var averagingTask: Task<(), Never>?

    /// Configuration for the participant view.
    struct Config {
        /// Whether to calculate end-to-end latency.
        let calculateLatency: Bool
        /// The time interval for the sliding window used to calculate end-to-end latency.
        let slidingWindowTime: TimeInterval
    }

    /// Create a new participant for the given identifier.
    /// - Parameter id: Namespace or source ID.
    /// - Parameter startDate: Join date of the call, for statistics.
    /// - Parameter subscribeDate: Subscribe date of the call, for statistics.
    /// - Parameter videoParticipants: The holder to register against.
    /// - Parameter participantId: The participant ID of this participant.
    /// - Parameter activeSpeakerStats: Stats/metrics object.
    init(id: SourceIDType,
         startDate: Date,
         subscribeDate: Date,
         videoParticipants: VideoParticipants,
         participantId: ParticipantId,
         activeSpeakerStats: ActiveSpeakerStats?,
         config: Config) throws {
        self.id = id
        self.label = id
        self.highlight = false
        self.startDate = startDate
        self.subscribeDate = subscribeDate
        self.videoParticipants = videoParticipants
        self.participantId = participantId
        self.activeSpeakerStats = activeSpeakerStats
        if config.calculateLatency {
            self.latencies = .init(config.slidingWindowTime)
            self.averagingTask = Task(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    if let self = self,
                       let latencies = self.latencies {
                        latencies.calc(from: .now)
                    }
                    try? await Task.sleep(for: .seconds(config.slidingWindowTime))
                }
            }
        } else {
            self.latencies = nil
        }
        try self.videoParticipants.add(self)
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
        Task { @MainActor in
            if details.usable {
                await stats.dataReceived(self.participantId, when: details.when.hostDate)
            } else {
                await stats.dataDropped(self.participantId, when: details.when.hostDate)
            }
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer,
                 transform: CATransform3D?,
                 when: Date,
                 endToEndLatency: TimeInterval?) throws {
        // Stats.
        if let stats = self.activeSpeakerStats {
            Task { @MainActor in
                guard let record = try? await stats.imageEnqueued(self.participantId, when: when) else {
                    self.logger.warning("[\(self.id)] Failed to record enqueue image")
                    return
                }
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

        if let endToEndLatency,
           let latencies = self.latencies {
            latencies.display.slidingWindow.add(timestamp: when, value: endToEndLatency)
        }

        // Enqueue the frame.
        self.display = true
        try self.view.enqueue(sampleBuffer, transform: transform)
    }

    deinit {
        self.logger.debug("[\(self.id)] Deinit")
        Task { [id, weak videoParticipants, logger] in
            guard let videoParticipants = videoParticipants else { return }
            await MainActor.run { [weak videoParticipants] in
                guard let videoParticipants = videoParticipants else { return }
                do {
                    try videoParticipants.removeParticipant(identifier: id)
                } catch {
                    logger.warning("[\(id)] Failed to remove participant")
                }
            }
        }
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

    private let logger = DecimusLogger(VideoParticipants.self)

    /// All tracked participants by identifier.
    private var weakParticipants: [SourceIDType: Weak<VideoParticipant>] = [:]
    var participants: [Weak<VideoParticipant>] { Array(self.weakParticipants.values) }

    /// Add a participant.
    /// - Parameter videoParticipant: The participant to add.
    /// - Throws: ``ParticipantError.alreadyExists`` if the participant has already been added.
    fileprivate func add(_ videoParticipant: VideoParticipant) throws {
        if self.weakParticipants[videoParticipant.id] != nil {
            throw ParticipantError.alreadyExists
        }
        self.weakParticipants[videoParticipant.id] = .init(videoParticipant)
        self.logger.debug("[\(videoParticipant.id)] Added participant")
    }

    /// Remove a participant view.
    /// - Parameter identifier: The identifier for the target view to remove.
    /// - Throws: ``ParticipantError.notFound`` if the participant is not found.
    fileprivate func removeParticipant(identifier: SourceIDType) throws {
        guard self.weakParticipants.removeValue(forKey: identifier) != nil else {
            throw ParticipantError.notFound
        }
        self.logger.debug("[\(identifier)] Removed participant")
    }
}
