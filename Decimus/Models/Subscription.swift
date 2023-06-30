import AVFoundation
import CoreMedia
import SwiftUI

// swiftlint:disable identifier_name
enum SubscriptionError: Int32 {
    case None = 0
    case NoDecoder
    case FailedDecoderCreation
}
// swiftlint:enable identifier_name

class SubscriptionOutputDelegate {

}

private class VideoSubscriptionOutputDelegate: SubscriptionOutputDelegate {

}

private class AudioSubscriptionOutputDelegate: SubscriptionOutputDelegate {

}

class Subscription: QSubscriptionDelegateObjC {

    private let namespace: QuicrNamespace
    private var decoder: Decoder?
    private unowned let participants: VideoParticipants
    private unowned let player: FasterAVEngineAudioPlayer
    private unowned let codecFactory: DecoderFactory

    init(namespace: QuicrNamespace,
         codecFactory: DecoderFactory,
         participants: VideoParticipants,
         player: FasterAVEngineAudioPlayer) {
        self.namespace = namespace
        self.codecFactory = codecFactory
        self.participants = participants
        self.player = player
    }

    deinit {
        do {
            try participants.removeParticipant(identifier: namespace)
        } catch {
            player.removePlayer(identifier: namespace)
        }
    }

    func prepare(_ sourceID: SourceIDType!, label: String!, qualityProfile: String!) -> Int32 {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile)

        do {
            switch config.codec {
            case .h264:
#if os(tvOS)
                let sampleDecoder = try codecFactory.create(config: config) { [weak self] image, timestamp, flip in
                    self?.showDecodedImage(decoded: image, timestamp: timestamp, verticalMirror: flip)
                }
#else
                let sampleDecoder = try codecFactory.create(config: config) { [weak self] image, timestamp, orientation, flip in
                    self?.showDecodedImage(decoded: image, timestamp: timestamp, orientation: orientation, verticalMirror: flip)
                }
#endif
                decoder = sampleDecoder
            default:
                return SubscriptionError.FailedDecoderCreation.rawValue
            }

            log("Subscribed to \(String(describing: config.codec)) stream for source \(sourceID!)")
        } catch {
            log("Failed to create decoder: \(error)")
            return SubscriptionError.FailedDecoderCreation.rawValue
        }

        return SubscriptionError.None.rawValue
    }

    func update(_ sourceId: String!, label: String!, qualityProfile: String!) -> Int32 {
        return SubscriptionError.NoDecoder.rawValue
    }

    func subscribedObject(_ data: Data!, groupId: UInt32, objectId: UInt16) -> Int32 {
        guard let decoder = decoder else {
            log("No decoder for Subscription. Did you forget to prepare?")
            return SubscriptionError.NoDecoder.rawValue
        }

        data.withUnsafeBytes {
            decoder.write(data: $0, timestamp: 0)
        }
        return SubscriptionError.None.rawValue
    }

#if !os(tvOS)
    private func showDecodedImage(decoded: CIImage,
                                  timestamp: CMTimeValue,
                                  orientation: AVCaptureVideoOrientation?,
                                  verticalMirror: Bool) {
        let participant = participants.getOrMake(identifier: namespace)

        // TODO: Why can't we use CIImage directly here?
        let image: CGImage = CIContext().createCGImage(decoded, from: decoded.extent)!
        let imageOrientation = orientation?.toImageOrientation(verticalMirror) ?? .up
        participant.decodedImage = .init(decorative: image, scale: 1.0, orientation: imageOrientation)
        participant.lastUpdated = .now()
    }
#else
    private func showDecodedImage(decoded: CIImage,
                                  timestamp: CMTimeValue,
                                  verticalMirror: Bool) {
        let participant = participants.getOrMake(identifier: namespace)

        // TODO: Why can't we use CIImage directly here?
        let image: CGImage = CIContext().createCGImage(decoded, from: decoded.extent)!
        participant.decodedImage = .init(decorative: image, scale: 1.0, orientation: .up)
        participant.lastUpdated = .now()
    }
#endif

    private func log(_ message: String) {
        print("[Subscription] (\(namespace)) \(message)")
    }
}

#if !os(tvOS)
extension AVCaptureVideoOrientation {
    func toImageOrientation(_ verticalMirror: Bool) -> Image.Orientation {
        let imageOrientation: Image.Orientation
        switch self {
        case .portrait:
            imageOrientation = verticalMirror ? .leftMirrored : .right
        case .landscapeLeft:
            imageOrientation = verticalMirror ? .upMirrored : .down
        case .landscapeRight:
            imageOrientation = verticalMirror ? .downMirrored : .up
        case .portraitUpsideDown:
            imageOrientation = verticalMirror ? .rightMirrored : .left
        default:
            imageOrientation = .up
        }
        return imageOrientation
    }
}
#endif
