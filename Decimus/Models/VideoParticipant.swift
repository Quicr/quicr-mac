import SwiftUI
import Combine

enum ParticipantError: Error {
    case notFound
}

class VideoParticipant: ObservableObject, Identifiable {
    var id: UInt64
    @Published var decodedImage: Image

    init(id: UInt64) {
        self.id = id
        decodedImage = .init(systemName: "phone")
    }
}

class VideoParticipants: ObservableObject {
    var participants: [UInt64: VideoParticipant] = [:]
    private var cancellables: [UInt64: AnyCancellable] = [:]

    func getOrMake(identifier: UInt64) -> VideoParticipant {
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

    func removeParticipant(identifier: UInt64) throws {
        let removed = participants.removeValue(forKey: identifier)
        guard removed != nil else { throw ParticipantError.notFound }
        removed!.objectWillChange.send()
        let cancellable = cancellables[identifier]
        cancellable!.cancel()
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        print("VideoParticipants => [\(identifier)] Removed participant")
    }
}
