import Foundation
import AVFoundation

class Publication: NSObject,
                   AVCaptureVideoDataOutputSampleBufferDelegate,
                   AVCaptureAudioDataOutputSampleBufferDelegate,
                   QPublicationDelegateObjC {

    private(set) var device: AVCaptureDevice?
    private(set) var queue: DispatchQueue?
    private var encoder: Encoder?
    private var sourceID: SourceIDType?
    private var qualityProfile: String?

    private var notifier: NotificationCenter = .default

    func prepare(_ sourceId: SourceIDType!, qualityProfile: String!) -> Int32 {
        self.sourceID = sourceId
        self.qualityProfile = qualityProfile
        self.device = AVCaptureDevice.init(uniqueID: sourceId)
        self.queue = .init(label: "com.cisco.quicr.decimus.\(sourceId!)",
                           target: .global(qos: .userInteractive))

        let config = CodecFactory.makeCodecConfig(from: qualityProfile)
        do {
            try encoder = CodecFactory.shared.createEncoder(config) { _ in }

            let mediaType: AVMediaType
            switch config.codec {
            case .h264:
                mediaType = .video
            case .opus:
                mediaType = .audio
            default:
                fatalError()
            }

            self.device = AVCaptureDevice.default(for: mediaType)
            log("Registered \(String(describing: config.codec)) publication for source \(sourceId!)")
        } catch {
            log("Failed to create encoder: \(error)")
            return 1
        }

        notifier.post(name: .publicationPreparedForDevice, object: self)
        return 0
    }

    func update(_ sourceId: String!, qualityProfile: String!) -> Int32 {
        return 1
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
        guard let sourceID = sourceID,
              let qualityProfile = qualityProfile else {
            fatalError("Must be called after prepare")
        }
        print("[Publication] (\(sourceID) \(qualityProfile)) \(message)")
    }
}

extension Notification.Name {
    static var publicationPreparedForDevice = Notification.Name("publicationPreparedForDevice")
}
