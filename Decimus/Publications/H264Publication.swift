import Foundation
import AVFoundation
import os

enum H264PublicationError: LocalizedError {
    case noCamera(SourceIDType)

    public var errorDescription: String? {
        switch self {
        case .noCamera:
            return "No camera available"
        }
    }
}

class H264Publication: NSObject, AVCaptureDevicePublication, FrameListener {
    private static let logger = DecimusLogger(H264Publication.self)

    private let measurement: VideoPublicationMeasurement?
    private let metricsSubmitter: MetricsSubmitter?

    let namespace: QuicrNamespace
    internal weak var publishObjectDelegate: QPublishObjectDelegateObjC?
    let device: AVCaptureDevice
    let queue: DispatchQueue

    private var encoder: VTEncoder
    private let reliable: Bool
    private let granularMetrics: Bool
    let codec: VideoCodecConfig?
    private var frameRate: Float64?
    private var startTime: Date?

    required init(namespace: QuicrNamespace,
                  publishDelegate: QPublishObjectDelegateObjC,
                  sourceID: SourceIDType,
                  config: VideoCodecConfig,
                  metricsSubmitter: MetricsSubmitter?,
                  reliable: Bool,
                  granularMetrics: Bool) throws {
        self.namespace = namespace
        self.publishObjectDelegate = publishDelegate
        self.granularMetrics = granularMetrics
        self.codec = config
        self.metricsSubmitter = metricsSubmitter
        if let metricsSubmitter = metricsSubmitter {
            self.measurement = .init(namespace: namespace)
        } else {
            self.measurement = nil
        }
        self.queue = .init(label: "com.cisco.quicr.decimus.\(namespace)",
                           target: .global(qos: .userInteractive))
        self.reliable = reliable

        // TODO: SourceID from manifest is bogus, do this for now to retrieve valid device
        if #available(iOS 17.0, tvOS 17.0, *) {
            guard let preferred = AVCaptureDevice.systemPreferredCamera else {
                throw H264PublicationError.noCamera(sourceID)
            }
            self.device = preferred
        } else {
            guard let preferred = AVCaptureDevice.default(for: .video) else {
                throw H264PublicationError.noCamera(sourceID)
            }
            self.device = preferred
        }

        let onEncodedData: VTEncoder.EncodedCallback = { [weak publishDelegate, measurement, namespace] presentationTimestamp, captureTime, data, flag in
            // Encode age.
            if granularMetrics,
               let measurement = measurement {
                let captureDate = Date(timeIntervalSinceReferenceDate: captureTime.seconds)
                let now = Date.now
                let age = now.timeIntervalSince(captureDate)
                Task(priority: .utility) {
                    await measurement.encoded(age: age, timestamp: now)
                }
            }

            // Publish.
            publishDelegate?.publishObject(namespace, data: data.baseAddress!, length: data.count, group: flag)

            // Metrics.
            guard let measurement = measurement else { return }
            let now: Date? = granularMetrics ? Date.now : nil
            let bytes = data.count
            Task(priority: .utility) {
                let age: TimeInterval?
                if let now = now {
                    let captureDate = Date(timeIntervalSinceReferenceDate: captureTime.seconds)
                    age = now.timeIntervalSince(captureDate)
                } else {
                    age = nil
                }
                await measurement.sentFrame(bytes: UInt64(bytes),
                                            timestamp: presentationTimestamp.seconds,
                                            age: age,
                                            metricsTimestamp: now)
            }
        }
        self.encoder = try .init(config: self.codec!,
                                 verticalMirror: device.position == .front,
                                 callback: onEncodedData,
                                 emitStartCodes: self.codec!.codec == .hevc)
        super.init()

        Self.logger.info("Registered H264 publication for source \(sourceID)")

        if let metricsSubmitter = self.metricsSubmitter,
           let measurement = self.measurement {
            Task(priority: .utility) {
                await metricsSubmitter.register(measurement: measurement)
            }
        }
    }

    deinit {
        if let measurement = self.measurement,
           let submitter = self.metricsSubmitter {
            let id = measurement.id
            Task(priority: .utility) {
                await submitter.unregister(id: id)
            }
        }
    }

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!, transportMode: UnsafeMutablePointer<TransportMode>!) -> Int32 {
        transportMode.pointee = self.reliable ? .reliablePerGroup : .unreliable
        return PublicationError.None.rawValue
    }

    func update(_ sourceId: String!, qualityProfile: String!) -> Int32 {
        return PublicationError.NoSource.rawValue
    }

    func publish(_ flag: Bool) {}

    /// This callback fires when a video frame arrives.
    func onFrame(_ sampleBuffer: CMSampleBuffer,
                 captureTime: Date) {
        // Configure FPS.
        if self.encoder.frameRate == nil {
            self.encoder.frameRate = self.device.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate
        }

        // Stagger the publication's start time by its height in ms.
        if let startTime = self.startTime {
            let interval = captureTime.timeIntervalSince(startTime)
            guard interval > TimeInterval(self.codec!.height / 1000) else {
                return
            }
        } else {
            self.startTime = captureTime
        }

        // Encode.
        do {
            try encoder.write(sample: sampleBuffer, captureTime: captureTime)
        } catch {
            Self.logger.error("Failed to encode frame: \(error.localizedDescription)")
        }

        // Metrics.
        guard let measurement = self.measurement else { return }
        guard let buffer = sampleBuffer.imageBuffer else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let pixels: UInt64 = .init(width * height)
        let presentationTimestamp = sampleBuffer.presentationTimeStamp.seconds
        let date: Date? = self.granularMetrics ? captureTime : nil
        let now = Date.now
        Task(priority: .utility) {
            await measurement.sentPixels(sent: pixels, timestamp: date)
            if let date = date {
                // TODO: This age is probably useless.
                let age = now.timeIntervalSince(captureTime)
                await measurement.age(age: age,
                                      presentationTimestamp: presentationTimestamp,
                                      metricsTimestamp: date)
            }
        }
    }
}
