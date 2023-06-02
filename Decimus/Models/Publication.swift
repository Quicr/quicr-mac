import Foundation
import AVFoundation

// swiftlint:disable identifier_name
enum PublicationError: Int32 {
    case None = 0
    case NoSource
    case FailedDecoderCreation
}
// swiftlint:enable identifier_name

class Publication: NSObject,
                   AVCaptureVideoDataOutputSampleBufferDelegate,
                   AVCaptureAudioDataOutputSampleBufferDelegate,
                   QPublicationDelegateObjC {
    private let id = UUID()
    private var notifier: NotificationCenter = .default

    private(set) var device: AVCaptureDevice?
    private(set) var queue: DispatchQueue?
    private var encoder: Encoder?
    private unowned let codecFactory: EncoderFactory

    init(codecFactory: EncoderFactory) {
        self.codecFactory = codecFactory
    }

    func prepare(_ sourceId: SourceIDType!, qualityProfile: String!) -> Int32 {
        // TODO: This should be the way to get device when sourceID is valid from manifest.
        // self.device = AVCaptureDevice.init(uniqueID: sourceId)
        // guard let device = self.device else {
        //    return PublicationError.NoSource.rawValue
        // }

        self.queue = .init(label: "com.cisco.quicr.decimus.\(id)",
                           target: .global(qos: .userInteractive))

        let config = CodecFactory.makeCodecConfig(from: qualityProfile)
        do {
            try encoder = codecFactory.create(config) { _ in }
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
            return PublicationError.FailedDecoderCreation.rawValue
        }

        notifier.post(name: .publicationPreparedForDevice, object: self)
        return PublicationError.NoSource.rawValue
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
            encoder.write(data: sampleBuffer.asMediaBuffer())
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
            let data = sampleBuffer.getMediaBuffer(userData: audioFormat)
            encoder.write(data: data)
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
        print("[Publication] (\(id)) \(message)")
    }
}

extension Notification.Name {
    static var publicationPreparedForDevice = Notification.Name("publicationPreparedForDevice")
}
