import Foundation

class Publisher {
    private unowned let client: MediaClient
    init(client: MediaClient) {
        self.client = client
    }

    private(set) var publications: [StreamIDType: Publication] = [:]

    func allocateByStream(streamID: StreamIDType) -> Publication {
        let publication = Publication(client: client)
        publications[streamID] = publication

        return publication
    }

    func removeByStream(streamID: StreamIDType) -> Bool {
        return publications.removeValue(forKey: streamID) != nil
    }
}
