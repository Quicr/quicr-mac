import SwiftUI
import Combine

enum ParticipantError: Error {
    case notFound
    case alreadyExists
    case mainThreadOnly
}

class VideoParticipant: ObservableObject, Identifiable {
    var id: SourceIDType
    let view: VideoView = .init()
    @Published var lastUpdated: DispatchTime

    init(id: SourceIDType) {
        self.id = id
        lastUpdated = .init(uptimeNanoseconds: 0)
    }
}

class VideoParticipants: ObservableObject {
    @Published var participants: [SourceIDType: VideoParticipant] = [:]
    private var cancellables: [SourceIDType: AnyCancellable] = [:]

    func get(identifier: SourceIDType) throws -> VideoParticipant {
        guard Thread.isMainThread else { throw ParticipantError.mainThreadOnly }
        guard let participant = participants[identifier] else { throw ParticipantError.notFound }
        return participant
    }

    func create(identifier: SourceIDType) throws {
        guard Thread.isMainThread else { throw ParticipantError.mainThreadOnly }
        if participants[identifier] != nil { throw ParticipantError.alreadyExists }

        let new: VideoParticipant = .init(id: identifier)
        let cancellable = new.objectWillChange.sink(receiveValue: {
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        })
        cancellables[identifier] = cancellable
        participants[identifier] = new
    }

    func removeParticipant(identifier: SourceIDType) throws {
        guard Thread.isMainThread else { throw ParticipantError.mainThreadOnly }
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
