import Foundation
import AVFoundation

// swiftlint:disable identifier_name
enum PublicationError: Int32 {
    case None = 0
    case NoSource
    case FailedEncoderCreation
}
// swiftlint:enable identifier_name

class Publication: NSObject,
                   AVCaptureVideoDataOutputSampleBufferDelegate,
                   AVCaptureAudioDataOutputSampleBufferDelegate,
                   QPublicationDelegateObjC {
    private var notifier: NotificationCenter = .default

    private let namespace: String
    private(set) var device: AVCaptureDevice?
    private(set) var queue: DispatchQueue?
    private var encoder: Encoder?
    private unowned let codecFactory: EncoderFactory
    private weak var publishDelegate: (QPublishObjectDelegateObjC)?

    init(namespace: String, publishDelegate: QPublishObjectDelegateObjC, codecFactory: EncoderFactory) {
        self.namespace = namespace
        self.publishDelegate = publishDelegate
        self.codecFactory = codecFactory
    }

    func prepare(_ sourceId: SourceIDType!, qualityProfile: String!) -> Int32 {
        // TODO: This should be the way to get device when sourceID is valid from manifest.
        // self.device = AVCaptureDevice.init(uniqueID: sourceId)
        // guard let device = self.device else {
        //    return PublicationError.NoSource.rawValue
        // }

        self.queue = .init(label: "com.cisco.quicr.decimus.\(namespace)",
                           target: .global(qos: .userInteractive))

        let config = CodecFactory.makeCodecConfig(from: qualityProfile)
        do {
            try encoder = codecFactory.create(config) { [weak self] in
                guard let self = self else { return }
                self.publishDelegate?.publishObject(self.namespace, data: $0, group: true) // FIXME - SAH
            }
            log("Registered \(String(describing: config.codec)) publication for source \(sourceId!)")

            // TODO: SourceID from manifest is bogus, do this for now to retrieve correct device
            let mediaType: AVMediaType
            switch config.codec {
            case .h264:
                mediaType = .video
            case .opus:
                mediaType = .audio
            default:
                return PublicationError.NoSource.rawValue
            }
            self.device = AVCaptureDevice.default(for: mediaType)
        } catch {
            log("Failed to create encoder: \(error)")
            return PublicationError.FailedEncoderCreation.rawValue
        }

        notifier.post(name: .publicationPreparedForDevice, object: self)
        return PublicationError.None.rawValue
    }

    func update(_ sourceId: String!, qualityProfile: String!) -> Int32 {
        return PublicationError.NoSource.rawValue
    }

    func publish(_ flag: Bool) {}

    /// This callback fires when a video frame arrives.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let encoder = encoder else {
            fatalError("[Publication] No encoder for Publisher. Did you forget to prepare?")
        }

        if device!.hasMediaType(.video) {
            encoder.write(sample: sampleBuffer)
        } else if device!.hasMediaType(.audio) {
            guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else {
                log("Couldn't get audio input format")
                return
            }
            
            guard asbd.mSampleRate == .opus48khz,
                  asbd.mChannelsPerFrame == 1,
                  asbd.mBytesPerFrame == 2 else {
                log("Microphone format not currently supported. Try a different mic")
                return
            }
            guard let formatDescription = sampleBuffer.formatDescription else {
                log("Missing format description")
                return
            }
            let audioFormat: AVAudioFormat = .init(cmAudioFormatDescription: formatDescription)
            encoder.write(data: sampleBuffer, format: audioFormat)
        }
    }

    /// This callback fires if a frame was dropped.
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        var mode: CMAttachmentMode = 0
        let reason = CMGetAttachment(sampleBuffer,
                                     key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: &mode)

        log(String(describing: reason))
    }

    private func log(_ message: String) {
        print("[Publication] (\(namespace)) \(message)")
    }
}

extension Notification.Name {
    static var publicationPreparedForDevice = Notification.Name("publicationPreparedForDevice")
}
