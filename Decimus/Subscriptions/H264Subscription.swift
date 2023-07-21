import AVFoundation
import CoreMedia
import SwiftUI
import QuartzCore

class H264Subscription: Subscription {
    internal let namespace: QuicrNamespace
    private var decoder: H264Decoder
    private unowned let participants: VideoParticipants

    init(namespace: QuicrNamespace,
         config: VideoCodecConfig,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter) {
        self.namespace = namespace
        self.participants = participants
        self.decoder = H264Decoder(config: config)

        self.decoder.registerCallback { [weak self] in
            self?.showDecodedImage(decoded: $0, timestamp: $1, orientation: $2, verticalMirror: $3)
        }

        log("Subscribed to H264 stream")
    }

    deinit {
        try? participants.removeParticipant(identifier: namespace)
    }

    func prepare(_ sourceID: SourceIDType!, label: String!, qualityProfile: String!) -> Int32 {
        return SubscriptionError.None.rawValue
    }

    func update(_ sourceId: String!, label: String!, qualityProfile: String!) -> Int32 {
        return SubscriptionError.NoDecoder.rawValue
    }

    func subscribedObject(_ data: Data!, groupId: UInt32, objectId: UInt16) -> Int32 {
        data.withUnsafeBytes {
            decoder.write(data: $0, timestamp: 0)
        }
        return SubscriptionError.None.rawValue
    }

    private func showDecodedImage(decoded: CMSampleBuffer,
                                  timestamp: CMTimeValue,
                                  orientation: AVCaptureVideoOrientation?,
                                  verticalMirror: Bool) {
        // FIXME: Driving from proper timestamps probably preferable.
        let array: CFArray! = CMSampleBufferGetSampleAttachmentsArray(decoded, createIfNecessary: true)
        let dictionary: CFMutableDictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0),
                                                            to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())

        // Enqueue the buffer.
        DispatchQueue.main.async {
            let participant = self.participants.getOrMake(identifier: self.namespace)
            guard let layer = participant.view.view.layer as? AVSampleBufferDisplayLayer else {
                fatalError()
            }
            guard layer.status != .failed else {
                print(layer.error!)
                layer.flush()
                return
            }
            layer.transform = orientation?.toTransform(verticalMirror) ?? CATransform3DIdentity
            layer.enqueue(decoded)
            participant.lastUpdated = .now()
        }
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

    func toTransform(_ verticalMirror: Bool) -> CATransform3D {
        var transform = CATransform3DIdentity
        switch self {
        case .portrait:
            transform = CATransform3DRotate(transform, .pi / 2, 0, 0, 1)
            if verticalMirror {
                transform = CATransform3DScale(transform, 1.0, -1.0, 1.0)
            }
        case .landscapeLeft:
            transform = CATransform3DRotate(transform, .pi, 0, 0, 1)
            if verticalMirror {
                transform = CATransform3DScale(transform, 1.0, -1.0, 1.0)
            }
        case .landscapeRight:
            transform = CATransform3DRotate(transform, -.pi, 0, 0, 1)
            if verticalMirror {
                transform = CATransform3DScale(transform, -1.0, 1.0, 1.0)
            }
        case .portraitUpsideDown:
            transform = CATransform3DRotate(transform, -.pi / 2, 0, 0, 1)
            if verticalMirror {
                transform = CATransform3DScale(transform, 1.0, -1.0, 1.0)
            }
        default:
            break
        }
        return transform
    }
}
