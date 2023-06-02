import AVFoundation
import CoreMedia
import SwiftUI

class Subscription: QSubscriptionDelegateObjC {

    private var sourceID: SourceIDType?
    private var decoder: Decoder?
    private unowned let participants: VideoParticipants
    private unowned let player: FasterAVEngineAudioPlayer
    private unowned let codecFactory: DecoderFactory

    init(codecFactory: DecoderFactory, participants: VideoParticipants, player: FasterAVEngineAudioPlayer) {
        self.codecFactory = codecFactory
        self.participants = participants
        self.player = player
    }

    deinit {
        guard let sourceID = sourceID else { return }
        do {
            try participants.removeParticipant(identifier: sourceID)
        } catch {
            player.removePlayer(identifier: sourceID)
        }
    }

    func prepare(_ sourceId: SourceIDType!, label: String!, qualityProfile: String!) -> Int32 {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile)
        sourceID = sourceId

        do {
            switch config.codec {
            case .opus:
                let bufferDecoder = try codecFactory.create(config: config) { [weak self] in
                    self?.playAudio(buffer: $0, timestamp: $1)
                }
                self.player.addPlayer(identifier: sourceId, format: bufferDecoder.decodedFormat)
                decoder = bufferDecoder
            case .h264:
                let sampleDecoder = try codecFactory.create(config: config) { [weak self] in
                    self?.showDecodedImage(decoded: $0, timestamp: $1, orientation: $2, verticalMirror: $3)
                }
                decoder = sampleDecoder
            default:
                return 1
            }

            log("Subscribed to \(String(describing: config.codec)) stream for source \(sourceId!)")
        } catch {
            log("Failed to create decoder: \(error)")
            return 1
        }

        return 0
    }

    func update(_ sourceId: String!, label: String!, qualityProfile: String!) -> Int32 {
        return 1
    }

    func subscribedObject(_ data: Data!) -> Int32 {
        guard let decoder = decoder else {
            log("No decoder for Subscription. Did you forget to prepare?")
            return 1
        }

        data.withUnsafeBytes {
            decoder.write(buffer: .init(buffer: $0, timestampMs: 0))
        }

        return 0
    }

    private func playAudio(buffer: AVAudioPCMBuffer, timestamp: CMTime?) {
        guard let sourceID = sourceID else {
            fatalError()
        }
        player.write(identifier: sourceID, buffer: buffer)
    }

    private func showDecodedImage(decoded: CIImage,
                                  timestamp: CMTimeValue,
                                  orientation: AVCaptureVideoOrientation?,
                                  verticalMirror: Bool) {
        guard let sourceID = sourceID else {
            fatalError()
        }

        let participant = participants.getOrMake(identifier: sourceID)

        // TODO: Why can't we use CIImage directly here?
        let image: CGImage = CIContext().createCGImage(decoded, from: decoded.extent)!
        let imageOrientation = orientation?.toImageOrientation(verticalMirror) ?? .up
        participant.decodedImage = .init(decorative: image, scale: 1.0, orientation: imageOrientation)
        participant.lastUpdated = .now()
    }

    private func log(_ message: String) {
        guard let sourceID = sourceID else {
            fatalError("[Subscription] No sourceID for Subscription. Did you forget to prepare?")
        }
        print("[Subscription] (\(sourceID)) \(message)")
    }
}

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
