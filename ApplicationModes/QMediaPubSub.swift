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
    private var codecLookup: [UInt64: CodecConfig] = [:]

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
                                                        timestampMs: UInt32(timestamp), userData: nil))
        QMediaPubSub.weakSelf!.pipeline!.decode(mediaBuffer: buffer)
    }

    func connect(config: CallConfig, onReady: () -> Void) throws {
        guard mediaClient == nil else { throw ApplicationError.alreadyConnected }

        QMediaPubSub.weakSelf = self
        mediaClient = .init(address: .init(string: config.address)!,
                            port: config.port,
                            protocol: config.connectionProtocol,
                            conferenceId: config.conferenceId)

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let manifest = await ManifestController.shared.getManifest(confId: config.conferenceId, email: config.email)
            mediaClient!.getStreamConfigs(manifest,
                                          prepareEncoderCallback: prepareEncoder,
                                          prepareDecoderCallback: prepareDecoder)
            semaphore.signal()
        }

        semaphore.wait()
        onReady()
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

    override func sendEncodedData(data: MediaBufferFromSource) {
        let buffer = data.media.buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let length: UInt32 = .init(data.media.buffer.count)
        let timestamp: UInt64 = .init(data.media.timestampMs)
        guard length > 0 else {
            errorHandler.writeError(message: "[QMediaPubSub] Data to send had length 0")
            return
        }

        let config = codecLookup[data.source]!
        if let _ = config as? AudioCodecConfig {
            mediaClient!.sendAudio(mediaStreamId: data.source,
                                   buffer: buffer,
                                   length: length,
                                   timestamp: timestamp)
            return
        }

        if let _ = config as? VideoCodecConfig {
            mediaClient!.sendVideoFrame(mediaStreamId: data.source,
                                        buffer: buffer,
                                        length: length,
                                        timestamp: timestamp,
                                        flag: false)
            return
        }
    }
}
