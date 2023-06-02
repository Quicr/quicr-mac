import SwiftUI
import Combine

enum ParticipantError: Error {
    case notFound
}

class VideoParticipant: ObservableObject, Identifiable {
    var id: SourceIDType
    @Published var decodedImage: Image
    var lastUpdated: DispatchTime

    init(id: SourceIDType) {
        self.id = id
        decodedImage = .init(systemName: "phone")
        lastUpdated = .init(uptimeNanoseconds: 0)
    }
}

class VideoParticipants: ObservableObject {
    var participants: [SourceIDType: VideoParticipant] = [:]
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

    func removeParticipant(identifier: SourceIDType) throws {
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
