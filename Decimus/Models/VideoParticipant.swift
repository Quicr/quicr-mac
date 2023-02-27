import SwiftUI
import Combine

class VideoParticipant: ObservableObject, Identifiable {
    var id: UInt32
    @Published var decodedImage: UIImage

    init(id: UInt32) {
        self.id = id
        decodedImage = .init(systemName: "phone")!
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
        let cancellable = new.objectWillChange.sink(receiveValue: { self.objectWillChange.send() })
        cancellables[identifier] = cancellable
        participants[identifier] = new
        return new
    }

    func removeParticipant(identifier: UInt32) {
        let removed = participants.removeValue(forKey: identifier)
        guard removed != nil else { fatalError("Participant \(identifier) doesn't exist") }
        removed!.objectWillChange.send()
        let cancellable = cancellables[identifier]
        cancellable!.cancel()
        objectWillChange.send()
        print("VideoParticipants => [\(identifier)] Removed participant")
    }
}
