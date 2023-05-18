import SwiftUI
import CoreMedia
import AVFoundation

enum ApplicationError: Error {
    case emptyEncoder
    case alreadyConnected
    case notConnected
}

class QMediaPubSub: ApplicationModeBase {
    static weak var weakSelf: QMediaPubSub?
    private var mediaClient: MediaClient?

    private var publishStreamIds: [UInt64: [UInt64]] = [:]
    private var streamIdMap: [UInt64] = []

    private var conferenceId: UInt32 = 1

    private let streamCallback: SubscribeCallback = { streamId, _, _, data, length, timestamp in
        guard QMediaPubSub.weakSelf != nil else {
            fatalError("[QMediaPubSub] Failed to find QMediaPubSub instance for stream: \(streamId)")
        }

        guard data != nil else {
            QMediaPubSub.weakSelf!.writeError(message: "[QMediaPubSub] [Subscription \(streamId)] Data was nil")
            return
        }

        let buffer = MediaBufferFromSource(source: streamId,
                                           media: .init(buffer: .init(start: data, count: Int(length)),
                                                        timestampMs: UInt32(timestamp)))
        QMediaPubSub.weakSelf!.pipeline!.decode(mediaBuffer: buffer)
    }

    func connect(config: CallConfig) async throws {
        guard mediaClient == nil else { throw ApplicationError.alreadyConnected }

        QMediaPubSub.weakSelf = self
        mediaClient = .init(address: .init(string: config.address)!,
                            port: config.port,
                            protocol: config.connectionProtocol,
                            conferenceId: config.conferenceId)

        let manifest = await ManifestController.shared.getManifest(confId: config.conferenceId, email: config.email)
        try mediaClient!.getStreamConfigs(manifest,
                                          prepareEncoderCallback: prepareEncoder,
                                          prepareDecoderCallback: prepareDecoder)
    }

    func disconnect() throws {
        guard mediaClient != nil else { throw ApplicationError.notConnected }

        publishStreamIds.values.forEach { $0.forEach { id in
            mediaClient!.removeMediaPublishStream(mediaStreamId: id)
            pipeline!.unregisterEncoder(identifier: id)
        }}
        publishStreamIds.removeAll()

        streamIdMap.forEach { id in
            mediaClient!.removeMediaSubscribeStream(mediaStreamId: id)
            pipeline!.unregisterDecoder(identifier: id)
        }
        streamIdMap.removeAll()

        mediaClient = nil
        QMediaPubSub.weakSelf = nil
    }

    private func writeError(message: String) {
        errorHandler.writeError(message: message)
    }

    private func prepareEncoder(sourceId: UInt64, mediaType: UInt8, endpoint: UInt16, config: CodecConfig) {
        let config = config
        let streamId = mediaClient!.addStreamPublishIntent(mediaType: mediaType, clientId: endpoint)
        if publishStreamIds[sourceId] == nil {
            publishStreamIds[sourceId] = [streamId]
        } else {
            publishStreamIds[sourceId]!.append(streamId)
        }

        self.pipeline!.registerEncoder(identifier: streamId, config: config)
        print("[QMediaPubSub] Registered \(String(describing: config.codec)) to publish stream: \(streamId)")
    }

    private func prepareDecoder(sourceId: UInt64, mediaType: UInt8, endpoint: UInt16, config: CodecConfig) {
        let streamId = mediaClient!.addStreamSubscribe(mediaType: mediaType,
                                                       clientId: endpoint,
                                                       callback: streamCallback)
        streamIdMap.append(streamId)

        self.pipeline!.registerDecoder(identifier: streamId, config: config)
        print("[QMediaPubSub] Subscribed to \(String(describing: config.codec)) stream: \(streamId)")
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

    override func getStreamIdFromDevice(_ identifier: UInt64) -> [UInt64] {
        guard let streamIds = publishStreamIds[identifier] else {
            fatalError("No mapping for \(identifier) to publish stream ID.")
        }
        return streamIds
    }

    override func removeRemoteSource(identifier: UInt64) {
        super.removeRemoteSource(identifier: identifier)
        mediaClient!.removeMediaSubscribeStream(mediaStreamId: identifier)
    }

    override func sendEncodedImage(identifier: UInt64, data: CMSampleBuffer) {
        do {
            try data.dataBuffer!.withUnsafeMutableBytes { ptr in
                let unsafe = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let timestampMs: UInt32
                do {
                    timestampMs = UInt32(try data.sampleTimingInfo(at: 0).presentationTimeStamp.seconds * 1000)
                } catch {
                    timestampMs = 0
                }

                mediaClient!.sendVideoFrame(mediaStreamId: identifier,
                                       buffer: unsafe,
                                       length: UInt32(data.dataBuffer!.dataLength),
                                       timestamp: UInt64(timestampMs),
                                       flag: false)
            }
        } catch {
            errorHandler.writeError(message: "[QMediaPubSub] Failed to get bytes of encoded image")
        }
    }

    override func sendEncodedAudio(data: MediaBufferFromSource) {
        guard data.media.buffer.count > 0 else {
            errorHandler.writeError(message: "[QMediaPubSub] Audio to send had length 0")
            return
        }
        mediaClient!.sendAudio(mediaStreamId: data.source,
                          buffer: data.media.buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                          length: UInt32(data.media.buffer.count),
                          timestamp: UInt64(data.media.timestampMs))
    }
}
