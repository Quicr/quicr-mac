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
    var cancellables: [AnyCancellable] = []

    func getOrMake(identifier: UInt32) -> VideoParticipant {

        if let participant = participants[identifier] {
            return participant
        }

        let new: VideoParticipant = .init(id: identifier)
        let cancellable = new.objectWillChange.sink(receiveValue: { self.objectWillChange.send() })
        self.cancellables.append(cancellable)
        participants[identifier] = new
        return new
    }
}
