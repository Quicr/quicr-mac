import Foundation
import AVFoundation

class Subscription: QSubscriptionDelegateObjC {

    private let player: FasterAVEngineAudioPlayer
    private var decoder: Decoder?

    init(errorWriter: ErrorWriter) {
        player = .init(errorWriter: errorWriter)
    }

    func prepare(_ sourceId: SourceIDType!, label: String!, qualityProfile: String!) -> Int32 {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile)

        do {
            decoder = try CodecFactory.shared.createDecoder(identifier: 0, config: config)
            if let decoder = decoder as? BufferDecoder {
                self.player.addPlayer(identifier: 0, format: decoder.decodedFormat)
            }

            print("[Subscriber] Subscribed to \(String(describing: config.codec)) stream for source \(sourceId!)")
        } catch {
            print("[Subscriber] Failed to create decoder: \(error)")
            return 1
        }

        return 0
    }

    func update(_ sourceId: String!, label: String!, qualityProfile: String!) -> Int32 {
        return 1
    }

    func subscribedObject(_ data: Data!) -> Int32 {
        guard let decoder = decoder else {
            fatalError("[Subscriber] No decoder for Subscriber. Did you forget to prepare?")
        }

        data.withUnsafeBytes {
            decoder.write(buffer: .init(buffer: $0, timestampMs: UInt32(NSDate().timeIntervalSince1970)))
        }

        return 0
    }
}
