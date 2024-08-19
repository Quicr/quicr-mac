import Foundation
import AVFoundation
import os
import MoqLoc

enum H264PublicationError: LocalizedError {
    case noCamera(SourceIDType)

    public var errorDescription: String? {
        switch self {
        case .noCamera:
            return "No camera available"
        }
    }
}

class RefPointer {
    var ptr: UnsafeMutableRawBufferPointer?
    deinit {
        self.ptr?.deallocate()
    }
}

class H264Publication: NSObject, AVCaptureDevicePublication, FrameListener {
    private static let logger = DecimusLogger(H264Publication.self)

    private let measurement: MeasurementRegistration<VideoPublicationMeasurement>?

    let namespace: QuicrNamespace
    internal weak var publishObjectDelegate: QPublishObjectDelegateObjC?
    let device: AVCaptureDevice
    let queue: DispatchQueue

    private var encoder: VideoEncoder
    private let reliable: Bool
    private let granularMetrics: Bool
    let codec: VideoCodecConfig?
    private var frameRate: Float64?
    private var startTime: Date?
    private let containerBacking = RefPointer()

    required init(namespace: QuicrNamespace,
                  publishDelegate: QPublishObjectDelegateObjC,
                  sourceID: SourceIDType,
                  config: VideoCodecConfig,
                  metricsSubmitter: MetricsSubmitter?,
                  reliable: Bool,
                  granularMetrics: Bool,
                  encoder: VideoEncoder,
                  device: AVCaptureDevice) throws {
        self.namespace = namespace
        self.publishObjectDelegate = publishDelegate
        self.granularMetrics = granularMetrics
        self.codec = config
        if let metricsSubmitter = metricsSubmitter {
            let measurement = H264Publication.VideoPublicationMeasurement(namespace: namespace)
            self.measurement = .init(measurement: measurement, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.queue = .init(label: "com.cisco.quicr.decimus.\(namespace)",
                           target: .global(qos: .userInteractive))
        self.reliable = reliable
        self.encoder = encoder
        self.device = device
        var onEncodedData: VTEncoder.EncodedCallback = { [weak publishDelegate, measurement, namespace, weak containerBacking] presentationTimestamp, data, flag, sequence in
            // Encode age.
            let now = measurement != nil && granularMetrics ? Date.now : nil
            if granularMetrics,
               let measurement = measurement {
                let age = now!.timeIntervalSince(presentationTimestamp)
                Task(priority: .utility) {
                    await measurement.measurement.encoded(age: age, timestamp: now!)
                }
            }

            // Low overhead container.
            let header = LowOverheadContainer.Header(timestamp: presentationTimestamp,
                                                     sequenceNumber: sequence)
            let data = Data(bytesNoCopy: .init(mutating: data.baseAddress!),
                            count: data.count,
                            deallocator: .none)
            let container = LowOverheadContainer(header: header, payload: [data])
            let requiredBytes = container.getRequiredBytes()
            guard let containerBacking = containerBacking else { return }
            if let workingMemory = containerBacking.ptr,
               workingMemory.count < requiredBytes {
                workingMemory.deallocate()
                containerBacking.ptr = nil
            }
            if containerBacking.ptr == nil {
                containerBacking.ptr = .allocate(byteCount: requiredBytes,
                                                 alignment: MemoryLayout<UInt8>.alignment)
            }
            guard let workingMemory = containerBacking.ptr else {
                Self.logger.error("Failed to allocate LOC memory")
                return
            }
            do {
                _ = try container.serialize(into: workingMemory)
            } catch {
                Self.logger.error("Failed to serialize LOC: \(error.localizedDescription)")
            }

            // Publish.
            publishDelegate?.publishObject(namespace,
                                           data: workingMemory.baseAddress!,
                                           length: requiredBytes,
                                           group: flag)

            // Metrics.
            guard let measurement = measurement else { return }
            let sent: Date? = granularMetrics ? Date.now : nil
            let bytes = workingMemory.count
            Task(priority: .utility) {
                let age: TimeInterval?
                if let sent = sent {
                    age = sent.timeIntervalSince(presentationTimestamp)
                } else {
                    age = nil
                }
                await measurement.measurement.sentFrame(bytes: UInt64(bytes),
                                                        timestamp: presentationTimestamp.timeIntervalSince1970,
                                                        age: age,
                                                        metricsTimestamp: sent)
            }
        }
        self.encoder.setCallback(onEncodedData)
        super.init()

        Self.logger.info("Registered H264 publication for source \(sourceID)")
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
                 timestamp: Date) {
        // Configure FPS.
        let maxRate = self.device.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate
        if self.encoder.frameRate == nil {
            self.encoder.frameRate = maxRate
        } else {
            if self.encoder.frameRate != maxRate {
                Self.logger.warning("Frame rate mismatch? Had: \(String(describing: self.encoder.frameRate)), got: \(String(describing: maxRate))")
            }
        }

        // Stagger the publication's start time by its height in ms.
        guard let startTime = self.startTime else {
            self.startTime = timestamp
            return
        }
        let interval = timestamp.timeIntervalSince(startTime)
        guard interval > TimeInterval(self.codec!.height) / 1000.0 else { return }

        // Encode.
        do {
            try encoder.write(sample: sampleBuffer, timestamp: timestamp)
        } catch {
            Self.logger.error("Failed to encode frame: \(error.localizedDescription)")
        }

        // Metrics.
        guard let measurement = self.measurement else { return }
        guard let buffer = sampleBuffer.imageBuffer else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let pixels: UInt64 = .init(width * height)
        let date: Date? = self.granularMetrics ? timestamp : nil
        let now = Date.now
        Task(priority: .utility) {
            await measurement.measurement.sentPixels(sent: pixels, timestamp: date)
            if let date = date {
                // TODO: This age is probably useless.
                let age = now.timeIntervalSince(timestamp)
                await measurement.measurement.age(age: age,
                                                  presentationTimestamp: timestamp.timeIntervalSince1970,
                                                  metricsTimestamp: date)
            }
        }
    }
}
