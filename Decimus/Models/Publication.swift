import Foundation
import AVFoundation

// swiftlint:disable identifier_name
enum PublicationError: Int32 {
    case None = 0
    case NoSource
    case FailedEncoderCreation
}
// swiftlint:enable identifier_name

actor PublicationMeasurement: Measurement {
    var name: String = "Publication"
    var fields: [Date?: [String: AnyObject]] = [:]
    var tags: [String: String] = [:]

    private var bytes: UInt64 = 0

    init(namespace: QuicrNamespace, submitter: MetricsSubmitter) {
        tags["namespace"] = namespace
        Task {
            await submitter.register(measurement: self)
        }
    }

    func sentBytes(sent: UInt64, timestamp: Date?) {
        self.bytes += sent
        record(field: "sentBytes", value: self.bytes as AnyObject, timestamp: timestamp)
    }
}

actor VideoMeasurement: Measurement {
    var name: String = "VideoPublication"
    var fields: [Date?: [String: AnyObject]] = [:]
    var tags: [String: String] = [:]

    private var pixels: UInt64 = 0

    init(namespace: QuicrNamespace, submitter: MetricsSubmitter) {
        tags["namespace"] = namespace
        Task {
            await submitter.register(measurement: self)
        }
    }

    func sentPixels(sent: UInt64, timestamp: Date?) {
        self.pixels += sent
        record(field: "sentPixels", value: self.pixels as AnyObject, timestamp: timestamp)
    }
}

class PublicationCaptureDelegate: NSObject {
    private let encoder: Encoder?
    let log: (String) -> Void

    init(encoder: Encoder?, log: @escaping (String) -> Void) {
        self.encoder = encoder
        self.log = log
    }

    fileprivate func checkEncoder() -> Encoder {
        guard let encoder = encoder else {
            fatalError("No encoder for Publisher. Did you forget to prepare?")
        }
        return encoder
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

        log(String(describing: reason))
    }
}

private class VideoPublicationCaptureDelegate: PublicationCaptureDelegate,
                                               FrameListener {
    let queue: DispatchQueue
    private let measurement: VideoMeasurement

    init(namespace: QuicrNamespace,
         submitter: MetricsSubmitter,
         encoder: Encoder?,
         queue: DispatchQueue,
         log: @escaping (String) -> Void) {
        measurement = .init(namespace: namespace, submitter: submitter)
        self.queue = queue
        super.init(encoder: encoder, log: log)
    }

    /// This callback fires when a video frame arrives.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Report pixel metrics.
        guard let buffer = sampleBuffer.imageBuffer else { return }
        let width = CVPixelBufferGetWidth(sampleBuffer.imageBuffer!)
        let height = CVPixelBufferGetHeight(sampleBuffer.imageBuffer!)
        let pixels: UInt64 = .init(width * height)
        let date = Date.now
        Task(priority: .utility) {
            await measurement.sentPixels(sent: pixels, timestamp: date)
        }

        // Encode.
        let encoder = checkEncoder()
        encoder.write(sample: sampleBuffer)
    }
}

private class AudioPublicationCaptureDelegate: PublicationCaptureDelegate,
                                               AVCaptureAudioDataOutputSampleBufferDelegate {
    /// This callback fires when a video frame arrives.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let encoder = checkEncoder()
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

class Publication: QPublicationDelegateObjC {
    private unowned let codecFactory: EncoderFactory
    private unowned let publishObjectDelegate: QPublishObjectDelegateObjC
    private unowned let metricsSubmitter: MetricsSubmitter
    private let measurement: PublicationMeasurement

    let namespace: QuicrNamespace
    let queue: DispatchQueue
    private(set) var device: AVCaptureDevice?
    private(set) var capture: PublicationCaptureDelegate?
    private let captureManager: CaptureManager

    init(namespace: QuicrNamespace,
         publishDelegate: QPublishObjectDelegateObjC,
         codecFactory: EncoderFactory,
         metricsSubmitter: MetricsSubmitter,
         captureManager: CaptureManager) {
        self.namespace = namespace
        self.publishObjectDelegate = publishDelegate
        self.codecFactory = codecFactory
        self.metricsSubmitter = metricsSubmitter
        self.queue = .init(label: "com.cisco.quicr.decimus.\(namespace)",
                           target: .global(qos: .userInteractive))
        self.measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        self.captureManager = captureManager
    }

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!) -> Int32 {
        // TODO: This should be the way to get device when sourceID is valid from manifest.
        // self.device = AVCaptureDevice.init(uniqueID: sourceId)
        // guard let device = self.device else {
        //    return PublicationError.NoSource.rawValue
        // }

        let config = CodecFactory.makeCodecConfig(from: qualityProfile)
        do {
            let encoder = try codecFactory.create(config) { [weak self] data, flag in
                guard let self = self else { return }
                let timestamp = Date.now
                let count = data.count
                Task(priority: .utility) {
                    await self.measurement.sentBytes(sent: UInt64(count), timestamp: timestamp)
                }
                self.publishObjectDelegate.publishObject(self.namespace, data: data, group: flag)
            }
            log("Registered \(String(describing: config.codec)) publication for source \(sourceID!)")

            let mediaType: AVMediaType
            switch config.codec {
            case .h264:
                capture = VideoPublicationCaptureDelegate(namespace: self.namespace,
                                                          submitter: self.metricsSubmitter,
                                                          encoder: encoder,
                                                          queue: queue) { [weak self] message in
                    self?.log(message)
                }
                mediaType = .video
            case .opus:
                capture = AudioPublicationCaptureDelegate(encoder: encoder) { [weak self] message in
                    self?.log(message)
                }
                mediaType = .audio
            default:
                return PublicationError.NoSource.rawValue
            }

            // TODO: SourceID from manifest is bogus, do this for now to retrieve correct device
            guard let device: AVCaptureDevice = .default(for: mediaType) else {
                return PublicationError.NoSource.rawValue
            }
            Task(priority: .medium) {
                await captureManager.addInput(device: device, delegateCapture: capture, queue: self.queue)
            }
        } catch {
            log("Failed to create encoder: \(error)")
            return PublicationError.FailedEncoderCreation.rawValue
        }

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
