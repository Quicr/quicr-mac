import SwiftUI
import Combine
import os

enum ParticipantError: Error {
    case notFound
}

class VideoParticipant: ObservableObject, Identifiable {
    var id: SourceIDType
    var view: VideoView = .init()

    init(id: SourceIDType) {
        self.id = id
        self.view.label = id
    }
}

class VideoParticipants: ObservableObject {
    private static let logger = DecimusLogger(VideoParticipants.self)

    @Published var participants: [SourceIDType: VideoParticipant] = [:]
    private var cancellables: [SourceIDType: AnyCancellable] = [:]

    func getOrMake(identifier: SourceIDType) -> VideoParticipant {
        if let participant = participants[identifier] {
            return participant
        }

        let new: VideoParticipant = .init(id: identifier)
        let cancellable = new.objectWillChange.sink(receiveValue: {
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        })
        cancellables[identifier] = cancellable
        participants[identifier] = new
        return new
    }

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
