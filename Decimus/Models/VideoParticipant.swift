import SwiftUI
import Combine

enum ParticipantError: Error {
    case notFound
}

class VideoParticipant: ObservableObject, Identifiable {
    var id: UInt32
    @Published var decodedImage: Image

    init(id: UInt32) {
        self.id = id
        decodedImage = .init(systemName: "phone")
    }
}

class VideoParticipants: ObservableObject {
    var participants: [UInt32: VideoParticipant] = [:]
    private var cancellables: [UInt32: AnyCancellable] = [:]

    func getOrMake(identifier: UInt32) -> VideoParticipant {

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

    func removeParticipant(identifier: UInt32) throws {
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
