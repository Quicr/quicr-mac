import Foundation
import AVFoundation

class H264Publication: NSObject, Publication, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let publicationMeasurement: PublicationMeasurement
    private let videoMeasurement: VideoMeasurement

    let namespace: QuicrNamespace
    internal weak var publishObjectDelegate: QPublishObjectDelegateObjC?
    var device: AVCaptureDevice?

    private var encoder: H264Encoder

    required init(namespace: QuicrNamespace,
                  publishDelegate: QPublishObjectDelegateObjC,
                  sourceID: SourceIDType,
                  config: VideoCodecConfig,
                  metricsSubmitter: MetricsSubmitter) {
        self.namespace = namespace
        self.publishObjectDelegate = publishDelegate
        self.publicationMeasurement = .init(namespace: namespace, submitter: metricsSubmitter)
        self.videoMeasurement = .init(namespace: namespace, submitter: metricsSubmitter)
        self.encoder = .init(config: config, verticalMirror: false)

        super.init()

        // TODO: SourceID from manifest is bogus, do this for now to retrieve valid device
        // guard let device = AVCaptureDevice.init(uniqueID: sourceId) else {
        guard let device = AVCaptureDevice.default(for: .video) else {
            log("Failed to register H264 publication for source \(sourceID)")
            fatalError()
        }
        self.device = device

        self.encoder.registerCallback { [weak self] data, flag in
            guard let self = self else { return }

            let timestamp = Date.now
            let count = data.count
            Task(priority: .utility) {
                await self.publicationMeasurement.sentBytes(sent: UInt64(count), timestamp: timestamp)
            }
            self.publishObjectDelegate?.publishObject(self.namespace, data: data, group: flag)
        }

        log("Registered H264 publication for source \(sourceID)")
    }

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!) -> Int32 {
        return PublicationError.None.rawValue
    }

    func update(_ sourceId: String!, qualityProfile: String!) -> Int32 {
        return PublicationError.NoSource.rawValue
    }

    func publish(_ flag: Bool) {}

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

    /// This callback fires when a video frame arrives.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Report pixel metrics.
        guard let buffer = sampleBuffer.imageBuffer else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let pixels: UInt64 = .init(width * height)
        let date = Date.now
        Task(priority: .utility) {
            await videoMeasurement.sentPixels(sent: pixels, timestamp: date)
        }

        // Encode.
        encoder.write(sample: sampleBuffer)
    }
}
