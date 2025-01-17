// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreMedia
import QuartzCore

enum ParticipantError: Error {
    case alreadyExists
    case notFound
}

/// Represents a visible video display.
@Observable
@MainActor
class VideoParticipant: Identifiable {
    typealias EnqueueNotify = () -> Void

    /// The identifier for this participant (either a namespace, or a source ID for an aggregate).
    let id: SourceIDType
    /// The SwiftUI view for video display.
    var view: VideoView
    /// The label to display under the video.
    var label: String
    /// True if this video should be highlighted.
    var highlight: Bool
    private let videoParticipants: VideoParticipants
    private let logger = DecimusLogger(VideoParticipant.self)
    private var enqueueNotify: EnqueueNotify?

    /// Create a new participant for the given identifier.
    /// - Parameter id: Namespace or source ID.
    /// - Parameter startDate: Join date of the call, for statistics.
    /// - Parameter subscribeDate: Subscribe date of the call, for statistics.
    /// - Parameter videoParticipants: The holder to register against.
    init(id: SourceIDType,
         startDate: Date,
         subscribeDate: Date,
         videoParticipants: VideoParticipants) throws {
        self.id = id
        self.label = id
        self.highlight = false
        self.view = VideoView(startDate: startDate, subscribeDate: subscribeDate)
        self.videoParticipants = videoParticipants
        try self.videoParticipants.add(self)
    }

    func registerEnqueueCallback(_ callback: @escaping EnqueueNotify) {
        self.enqueueNotify = callback
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, transform: CATransform3D?) throws {
        self.enqueueNotify?()
        try self.view.enqueue(sampleBuffer, transform: transform)
    }

    deinit {
        self.logger.debug("[\(self.id)] Deinit")
        Task { [id, videoParticipants, logger] in
            await MainActor.run {
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
    typealias EnqueueNotify = (SourceIDType) -> Void
    class Weak<T: AnyObject>: Identifiable {
        weak var value: T?
        init(_ value: T) {
            self.value = value
        }
    }

    private let logger = DecimusLogger(VideoParticipants.self)
    private let notify: EnqueueNotify?

    /// All tracked participants by identifier.
    private var weakParticipants: [SourceIDType: Weak<VideoParticipant>] = [:]
    var participants: [Weak<VideoParticipant>] { Array(self.weakParticipants.values) }

    init(_ notify: EnqueueNotify?) {
        self.notify = notify
    }

    /// Add a participant.
    /// - Parameter videoParticipant: The participant to add.
    /// - Throws: ``ParticipantError.alreadyExists`` if the participant has already been added.
    fileprivate func add(_ videoParticipant: VideoParticipant) throws {
        if self.weakParticipants[videoParticipant.id] != nil {
            throw ParticipantError.alreadyExists
        }
        self.weakParticipants[videoParticipant.id] = .init(videoParticipant)
        self.logger.debug("[\(videoParticipant.id)] Added participant")
        if self.notify != nil {
            videoParticipant.registerEnqueueCallback { [weak self] in
                guard let self = self else { return }
                self.notify!(videoParticipant.id)
            }
        }
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
