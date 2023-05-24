import SwiftUI
import CoreMedia
import AVFoundation

enum ApplicationError: Error {
    case emptyEncoder
    case alreadyConnected
    case notConnected
}

class QMediaPubSub: ApplicationMode {
    private let devices = Devices()
    private var codecLookup: [UInt64: CodecConfig] = [:]

    private var mediaClient: MediaClient?
    private var publishers: [SourceIDType: [Publisher]] = [:]
    private var subscribers: [SourceIDType: [Subscriber]] = [:]

    override func connect(config: CallConfig) async throws {
        guard mediaClient == nil else { throw ApplicationError.alreadyConnected }

        mediaClient = .init(address: .init(string: config.address)!,
                            port: config.port,
                            protocol: config.connectionProtocol,
                            conferenceId: config.conferenceId)

        let manifest = await ManifestController.shared.getManifest(confId: config.conferenceId, email: config.email)
        try mediaClient!.getStreamConfigs(manifest,
                                          prepareEncoderCallback: prepareEncoder,
                                          prepareDecoderCallback: prepareDecoder)
    }

    override func disconnect() throws {
        guard mediaClient != nil else { throw ApplicationError.notConnected }

        publishers.removeAll()
        subscribers.removeAll()
        mediaClient = nil
    }

    private func prepareEncoder(sourceId: SourceIDType, mediaType: UInt8, endpoint: UInt16, qualityProfile: String) {
        guard devices.devices.first(where: { $0.uniqueID == sourceId }) != nil else {
            fatalError("Invalid sourceId \"\(sourceId)\": No device found")
        }

        let publisher = Publisher(client: mediaClient!)
        let streamId = mediaClient!.addStreamPublishIntent(mediaType: mediaType, clientId: endpoint)

        do {
            codecLookup[streamId] = try publisher.prepareByStream(streamId: streamId,
                                                                  sourceId: sourceId,
                                                                  qualityProfile: qualityProfile)

            if publishers[sourceId] == nil {
                publishers[sourceId] = [publisher]
            } else {
                publishers[sourceId]!.append(publisher)
            }
        } catch {
            mediaClient!.removeMediaPublishStream(mediaStreamId: streamId)
        }
    }

    private func prepareDecoder(sourceId: SourceIDType, mediaType: UInt8, endpoint: UInt16, qualityProfile: String) {
        let subscriber = Subscriber(client: mediaClient!)
        let streamId = mediaClient!.addStreamSubscribe(mediaType: mediaType,
                                                       clientId: endpoint,
                                                       callback: subscriber.subscribedObject)

        // if let decoder = decoder as? BufferDecoder {
        //     self.player.addPlayer(identifier: streamId, format: decoder.decodedFormat)
        // }
        do {
            try subscriber.prepareByStream(streamId: streamId,
                                         sourceId: sourceId,
                                         qualityProfile: qualityProfile)

            if subscribers[sourceId] == nil {
                subscribers[sourceId] = [subscriber]
            } else {
                subscribers[sourceId]!.append(subscriber)
            }
        } catch {
            mediaClient!.removeMediaSubscribeStream(mediaStreamId: streamId)
        }
    }

    override func onDeviceChange(device: AVCaptureDevice, event: CaptureManager.DeviceEvent) {
        switch event {
        case .added:
            print()
        case .removed:
            print()
        }
        ManifestController.shared.sendCapabilities()
    }

    override func encodeCameraFrame(identifier: SourceIDType, frame: CMSampleBuffer) {
        guard let publishers = publishers[identifier] else {
            fatalError("No publishers matching sourceId: \(identifier)")
        }
        Task { await publishers.concurrentForEach { $0.write(sample: frame) } }
    }

    override func encodeAudioSample(identifier: SourceIDType, sample: CMSampleBuffer) {
        guard let publisher = publishers[identifier] else {
            fatalError("No publishers matching sourceId: \(identifier)")
        }

        guard let formatDescription = sample.formatDescription else {
            errorHandler.writeError(message: "Missing format description")
            return
        }
        let audioFormat: AVAudioFormat = .init(cmAudioFormatDescription: formatDescription)
        let data = sample.getMediaBuffer(userData: audioFormat)
        publisher.forEach { $0.write(data: data) }
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
