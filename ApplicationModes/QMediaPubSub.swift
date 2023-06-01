import SwiftUI
import CoreMedia
import AVFoundation

enum ApplicationError: Error {
    case emptyEncoder
    case alreadyConnected
    case notConnected
}

class QMediaPubSub: ApplicationMode {
    private var mediaClient: MediaClient?
    private var publisher: Publisher?
    private var subscriber: Subscriber?

    override func connect(config: CallConfig) async throws {
        guard mediaClient == nil else { throw ApplicationError.alreadyConnected }

        mediaClient = .init(address: .init(string: config.address)!,
                            port: config.port,
                            protocol: config.connectionProtocol,
                            conferenceId: config.conferenceId)

        publisher = .init(client: self.mediaClient!)
        subscriber = .init(client: self.mediaClient!, player: self.player)

        let manifest = await ManifestController.shared.getManifest(confId: config.conferenceId, email: config.email)
        try mediaClient!.getStreamConfigs(manifest,
                                          prepareEncoderCallback: preparePublication,
                                          prepareDecoderCallback: prepareSubscription)

        notifier.post(name: .connected, object: self)
    }

    override func disconnect() throws {
        guard mediaClient != nil else { throw ApplicationError.notConnected }

        publisher = nil
        subscriber = nil
        mediaClient = nil
    }

    private func preparePublication(sourceId: SourceIDType,
                                    mediaType: UInt8,
                                    endpoint: UInt16,
                                    qualityProfile: String) {
        guard let publisher = publisher else {
            fatalError("[QMediaPubSub] No publisher setup, did you forget to connect?")
        }

        let streamID = mediaClient!.addStreamPublishIntent(mediaType: mediaType, clientId: endpoint)
        let publication = publisher.allocateByStream(streamID: streamID)

        do {
            try publication.prepare(streamID: streamID, sourceID: sourceId, qualityProfile: qualityProfile)
        } catch {
            mediaClient!.removeMediaPublishStream(mediaStreamId: streamID)
        }
    }

    private func prepareSubscription(sourceId: SourceIDType,
                                     mediaType: UInt8,
                                     endpoint: UInt16,
                                     qualityProfile: String) {
        guard let subscriber = subscriber else {
            fatalError("[QMediaPubSub] No subscriber setup, did you forget to connect?")
        }

        let subscription = subscriber.allocateByStream(streamID: 0)
        /*
        let streamID = mediaClient!.addStreamSubscribe(mediaType: mediaType,
                                                       clientId: endpoint,
                                                       callback: subscription.subscribedObject)
        subscriber.updateSubscriptionStreamID(streamID: streamID)
        do {
            try subscription.prepare(streamID: streamID, sourceID: sourceId, qualityProfile: qualityProfile)
        } catch {
            mediaClient!.removeMediaSubscribeStream(mediaStreamId: streamID)
        }
         */
    }
}

extension Sequence {
    func concurrentForEach(_ operation: @escaping (Element) async -> Void) async {
        // A task group automatically waits for all of its
        // sub-tasks to complete, while also performing those
        // tasks in parallel:
        await withTaskGroup(of: Void.self) { group in
            for element in self {
                group.addTask {
                    await operation(element)
                }
            }
        }
    }
}
