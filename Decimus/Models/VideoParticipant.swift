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
         activeSpeakerStats: ActiveSpeakerStats?) throws {
        self.id = id
        self.label = id
        self.highlight = false
        self.startDate = startDate
        self.subscribeDate = subscribeDate
        self.videoParticipants = videoParticipants
        self.participantId = participantId
        self.activeSpeakerStats = activeSpeakerStats
        try self.videoParticipants.add(self)
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, transform: CATransform3D?, when: Date) throws {
        // Stats.
        if let stats = self.activeSpeakerStats {
            Task { @MainActor in
                let record = await stats.imageEnqueued(self.participantId, when: when)
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
