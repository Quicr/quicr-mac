import Foundation
import AVFoundation

// swiftlint:disable identifier_name
enum PublicationError: Int32 {
    case None = 0
    case NoSource
    case FailedEncoderCreation
}
// swiftlint:enable identifier_name

class PublicationCaptureDelegate: NSObject {
    fileprivate let encoder: Encoder
    let log: (String) -> Void
    fileprivate let errorWriter: ErrorWriter

    init(encoder: Encoder, errorWriter: ErrorWriter, log: @escaping (String) -> Void) {
        self.encoder = encoder
        self.log = log
        self.errorWriter = errorWriter
    }

    /// This callback fires if a frame was dropped.
    @objc(captureOutput:didDropSampleBuffer:fromConnection:)
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        var mode: CMAttachmentMode = 0
        let reason = CMGetAttachment(sampleBuffer,
                                     key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: &mode)
        errorWriter.writeError("Dropped frame: \(String(describing: reason))")
        log(String(describing: reason))
    }
}

private class VideoPublicationCaptureDelegate: PublicationCaptureDelegate,
                                               AVCaptureVideoDataOutputSampleBufferDelegate {
    /// This callback fires when a video frame arrives.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        do {
            try encoder.write(sample: sampleBuffer)
        } catch {
            // TODO: Show this error.
            let message = "Failed to encode video frame: \(error.localizedDescription)"
            log(message)
            errorWriter.writeError(message)
        }
    }
}

private class AudioPublicationCaptureDelegate: PublicationCaptureDelegate,
                                               AVCaptureAudioDataOutputSampleBufferDelegate {
    /// This callback fires when a video frame arrives.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else {
            let message = "Couldn't get audio input format"
            errorWriter.writeError(message)
            return
        }

        guard asbd.mSampleRate == .opus48khz,
              asbd.mChannelsPerFrame == 1,
              asbd.mBytesPerFrame == 2 else {
            log("Microphone format not currently supported. Try a different mic")
            return
        }
        guard let formatDescription = sampleBuffer.formatDescription else {
            let message = "Missing format description"
            log(message)
            errorWriter.writeError(message)
            return
        }
        let audioFormat: AVAudioFormat = .init(cmAudioFormatDescription: formatDescription)
        do {
            try encoder.write(data: sampleBuffer, format: audioFormat)
        } catch {
            let message = "Failed to encode audio sample: \(error.localizedDescription)"
            log(message)
            errorWriter.writeError(message)
        }
    }
}

class Publication: QPublicationDelegateObjC {
    private let notifier: NotificationCenter = .default

    private unowned let publishObjectDelegate: QPublishObjectDelegateObjC
    private let codecFactory: EncoderFactory
    private let metricsSubmitter: MetricsSubmitter

    let namespace: QuicrNamespace
    let queue: DispatchQueue
    private(set) var device: AVCaptureDevice?
    private var encoder: Encoder?
    private(set) var capture: PublicationCaptureDelegate?
    private let errorWriter: ErrorWriter

    init(namespace: QuicrNamespace,
         publishDelegate: QPublishObjectDelegateObjC,
         codecFactory: EncoderFactory,
         metricsSubmitter: MetricsSubmitter,
         errorWriter: ErrorWriter) {
        self.namespace = namespace
        self.publishObjectDelegate = publishDelegate
        self.codecFactory = codecFactory
        self.metricsSubmitter = metricsSubmitter
        self.queue = .init(label: "com.cisco.quicr.decimus.\(namespace)",
                           target: .global(qos: .userInteractive))
        self.errorWriter = errorWriter
    }

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!) -> Int32 {
        // TODO: This should be the way to get device when sourceID is valid from manifest.
        // self.device = AVCaptureDevice.init(uniqueID: sourceId)
        // guard let device = self.device else {
        //    return PublicationError.NoSource.rawValue
        // }

        let config = CodecFactory.makeCodecConfig(from: qualityProfile)
        do {
            encoder = try codecFactory.create(config) { [weak self] in
                guard let publication = self else { return }
                publication.publishObjectDelegate.publishObject(publication.namespace, data: $0, group: $1)
            }
            log("Registered \(String(describing: config.codec)) publication for source \(sourceID!)")

            let mediaType: AVMediaType
            switch config.codec {
            case .h264:
                capture = VideoPublicationCaptureDelegate(encoder: encoder!, errorWriter: errorWriter) { [weak self] in
                    self?.log($0)
                }
                mediaType = .video
            case .opus:
                capture = AudioPublicationCaptureDelegate(encoder: encoder!, errorWriter: errorWriter) { [weak self] in
                    self?.log($0)
                }
                mediaType = .audio
            default:
                return PublicationError.NoSource.rawValue
            }

            // TODO: SourceID from manifest is bogus, do this for now to retrieve correct device
            self.device = AVCaptureDevice.default(for: mediaType)
        } catch {
            let message = "Failed to create encoder: \(error.localizedDescription)"
            errorWriter.writeError(message)
            log(message)
            return PublicationError.FailedEncoderCreation.rawValue
        }

        notifier.post(name: .publicationPreparedForDevice, object: self)
        return PublicationError.None.rawValue
    }

    func update(_ sourceId: String!, qualityProfile: String!) -> Int32 {
        return PublicationError.NoSource.rawValue
    }

    func publish(_ flag: Bool) {}

    private func log(_ message: String) {
        print("[Publication] (\(namespace)) \(message)")
    }
}

extension Notification.Name {
    static var publicationPreparedForDevice = Notification.Name("publicationPreparedForDevice")
}
