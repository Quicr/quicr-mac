// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
import Combine
import os

enum ParticipantError: Error {
    case notFound
}

/// Represents a visible video display.
class VideoParticipant: ObservableObject, Identifiable {
    /// The identifier for this participant (either a namespace, or a source ID for an aggregate).
    var id: SourceIDType
    /// The SwiftUI view for video display.
    var view: VideoView
    /// The label to display under the video.
    @Published var label: String
    /// True if this video should be highlighted.
    @Published var highlight: Bool

    /// Create a new participant for the given identifier.
    /// - Parameter id: Namespace or source ID.
    init(id: SourceIDType, startDate: Date, subscribeDate: Date) {
        self.id = id
        self.label = id
        self.highlight = false
        self.view = VideoView(startDate: startDate, subscribeDate: subscribeDate)
    }
}

/// Holder for all video participants.
class VideoParticipants: ObservableObject {
    private static let logger = DecimusLogger(VideoParticipants.self)

    /// All tracked participants by identifier.
    @Published var participants: [SourceIDType: VideoParticipant] = [:]
    private var cancellables: [SourceIDType: AnyCancellable] = [:]
    private let startDate = Date.now

    /// Get or create a ``VideoParticipant``.
    /// - Parameter identifier: The identifier for the target view.
    /// - Returns: The created video view.
    func getOrMake(identifier: SourceIDType, subscribeDate: Date) -> VideoParticipant {
        if let participant = participants[identifier] {
            return participant
        }

        let new: VideoParticipant = .init(id: identifier, startDate: self.startDate, subscribeDate: subscribeDate)
        let cancellable = new.objectWillChange.sink(receiveValue: {
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        })
        cancellables[identifier] = cancellable
        participants[identifier] = new
        return new
    }

    /// Remove a participant view.
    /// - Parameter identifier: The identifier for the target view to remove.
    func removeParticipant(identifier: SourceIDType) {
        DispatchQueue.main.async {
            guard let removed = self.participants.removeValue(forKey: identifier) else {
                return
            }
            removed.objectWillChange.send()
            let cancellable = self.cancellables[identifier]
            cancellable!.cancel()
            self.cancellables.removeValue(forKey: identifier)
            self.objectWillChange.send()
            Self.logger.info("[\(identifier)] Removed participant")
        }
    }
}
