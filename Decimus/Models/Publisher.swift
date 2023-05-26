import Foundation

class Publisher {
    private unowned let client: MediaClient
    private(set) var publications: [StreamIDType: Publication] = [:]

    init(client: MediaClient) {
        self.client = client
    }

    deinit {
        publications.forEach { client.removeMediaPublishStream(mediaStreamId: $0.key) }
    }

    func allocateByStream(streamID: StreamIDType) -> Publication {
        let publication = Publication(client: client)
        publications[streamID] = publication
        return publication
    }

    func removeByStream(streamID: StreamIDType) -> Bool {
        return publications.removeValue(forKey: streamID) != nil
    }
}
