// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import AVFoundation
import Synchronization

enum H264PublicationError: LocalizedError {
    case noCamera(SourceIDType)

    public var errorDescription: String? {
        switch self {
        case .noCamera:
            return "No camera available"
        }
    }
}

/// H264 video publication using composition with MoQSink.
class H264Publication: MoQSinkDelegate, FrameListener, PublicationInstance {
    private let logger = DecimusLogger(H264Publication.self)

    // MARK: - Composition: MoQSink instead of inheritance

    /// The MoQ sink for publishing objects.
    let sink: MoQSink

    /// Mirror the legacy Publication API so tests can override publishing state.
    func canPublish() -> Bool {
        self.sink.canPublish
    }

    func getStatus() -> QPublishTrackHandlerStatus {
        self.sink.status
    }

    // MARK: - Configuration (previously from Publication base class)

    internal let profile: Profile
    internal let defaultPriority: UInt8
    internal let defaultTTL: UInt16
    private let trackMeasurement: MeasurementRegistration<TrackMeasurement>?

    // MARK: - Publication-specific state

    private let measurement: MeasurementRegistration<VideoPublicationMeasurement>?

    let device: AVCaptureDevice
    let queue: DispatchQueue

    private var encoder: VideoEncoder
    private let reliable: Bool
    private let granularMetrics: Bool
    let codec: VideoCodecConfig?
    private var frameRate: Float64?
    private var startTime: Date?
    private var currentGroupId: UInt64?
    private var currentObjectId: UInt64 = 0
    private let generateKeyFrame = Atomic(false)
    private let stagger: Bool
    private let publishFailure = Atomic(false)
    private let verbose: Bool
    private let keyFrameOnUpdate: Bool
    private let startCode: [UInt8] = [ 0x00, 0x00, 0x00, 0x01 ]
    private let emitStartCodes = false
    private var sequence: UInt64 = 0
    private let sframeContext: SendSFrameContext?
    private let mediaInterop: Bool

    // Encoded frames arrive in this callback.
    private let onEncodedData: VTEncoder.EncodedCallback = { presentationDate, sample, userData in
        guard let userData = userData else {
            assert(false)
            return
        }
        let publication = Unmanaged<H264Publication>.fromOpaque(userData).takeUnretainedValue()

        var extensions = HeaderExtensions()

        // Prepend format data.
        let extradata: Data?
        let idr = sample.isIDR()
        if idr {
            // SPS + PPS.
            guard let parameterSets = try? publication.handleParameterSets(sample: sample) else {
                publication.logger.error("Failed to handle parameter sets")
                return
            }

            if publication.mediaInterop {
                // For media interop, extradata is AVCDecoderConfigurationRecord.
                let avccData: Data
                guard let description = sample.formatDescription,
                      let extracted = H264Utilities.extractAVCCAtom(from: description) else {
                    publication.logger.error("Failed to parse AVCDecoderConfigurationRecord")
                    return
                }
                avccData = extracted
                do {
                    try extensions.setHeader(.videoH264AVCCExtradata(avccData))
                } catch {
                    publication.logger.error("Failed to set extradata header: \(error.localizedDescription)")
                    return
                }
                extradata = nil
            } else {
                let totalSize = parameterSets.reduce(0) { current, set in
                    current + set.count + publication.startCode.count
                }

                var workingExtradata = Data(count: totalSize)
                workingExtradata.withUnsafeMutableBytes { parameterDestination in
                    var offset = 0
                    for set in parameterSets {
                        // Copy either start code or UInt32 length.
                        if publication.emitStartCodes {
                            publication.startCode.withUnsafeBytes {
                                parameterDestination.baseAddress!.advanced(by: offset).copyMemory(from: $0.baseAddress!,
                                                                                                  byteCount: $0.count)
                                offset += $0.count
                            }
                        } else {
                            let length = UInt32(set.count).bigEndian
                            parameterDestination.storeBytes(of: length, toByteOffset: offset, as: UInt32.self)
                            offset += MemoryLayout<UInt32>.size
                        }

                        // Copy the parameter data.
                        let dest = parameterDestination.baseAddress!.advanced(by: offset)
                        let destBuffer = UnsafeMutableRawBufferPointer(start: dest,
                                                                       count: parameterDestination.count - offset)
                        destBuffer.copyMemory(from: set)
                        offset += set.count
                    }
                }
                extradata = workingExtradata
            }
        } else {
            extradata = nil
        }

        // Per frame extensions.
        do {
            if publication.mediaInterop {
                try extensions.setHeader(.videoH264AVCCMetadata(.init(sample: sample,
                                                                      sequence: publication.sequence,
                                                                      date: presentationDate)))
            } else {
                try extensions.setHeader(.captureTimestamp(presentationDate))
                try extensions.setHeader(.sequenceNumber(publication.sequence))
            }
        } catch {
            publication.logger.error("Failed to set media extensions: \(error.localizedDescription)")
        }

        let buffer = sample.dataBuffer!
        var offset = 0
        if publication.emitStartCodes {
            // Replace buffer data with start code.
            while offset < buffer.dataLength - publication.startCode.count {
                do {
                    try buffer.withUnsafeMutableBytes(atOffset: offset) {
                        // Get the length.
                        let naluLength = $0.loadUnaligned(as: UInt32.self).byteSwapped

                        // Replace with start code.
                        $0.copyBytes(from: publication.startCode)

                        // Move to next NALU.
                        offset += publication.startCode.count + Int(naluLength)
                    }
                } catch {
                    publication.logger.error("Failed to get byte pointer: \(error.localizedDescription)")
                    return
                }
            }
        }

        // Determine group and object IDs.
        let thisGroupId: UInt64
        let thisObjectId: UInt64
        if let currentGroupId = publication.currentGroupId {
            if idr {
                // Start new group on key frame.
                thisGroupId = currentGroupId + 1
                thisObjectId = 0
            } else {
                // Increment object ID in current GOP.
                thisGroupId = currentGroupId
                thisObjectId = publication.currentObjectId + 1
            }
        } else {
            // Start initial group ID using current time.
            assert(idr)
            thisGroupId = UInt64(Date.now.timeIntervalSince1970)
            thisObjectId = 0
        }

        // Publish.
        var protected: Data?
        let status = try! buffer.withContiguousStorage { ptr in // swiftlint:disable:this force_try
            let data: Data
            if let extradata {
                let sampleData = Data(bytes: ptr.baseAddress!, count: ptr.count)
                data = extradata + sampleData
            } else {
                data = .init(bytesNoCopy: .init(mutating: ptr.baseAddress!),
                             count: ptr.count,
                             deallocator: .none)
            }

            let protected: Data
            if let sframeContext = publication.sframeContext {
                do {
                    protected = try sframeContext.context.mutex.withLock { context in
                        try context.protect(epochId: sframeContext.currentEpoch,
                                            senderId: sframeContext.senderId,
                                            plaintext: data)
                    }
                } catch {
                    publication.logger.error("Failed to protect data: \(error.localizedDescription)")
                    return (QPublishObjectStatus.internalError, 0)
                }
            } else {
                protected = data
            }
            var priority = publication.getPriority(idr ? 0 : 1)
            var ttl = publication.getTTL(idr ? 0 : 1)
            return (publication.publish(groupId: thisGroupId,
                                        objectId: thisObjectId,
                                        data: protected,
                                        priority: &priority,
                                        ttl: &ttl,
                                        extensions: nil,
                                        immutableExtensions: extensions),
                    protected.count)
        }
        switch status.0 {
        case .ok:
            if publication.verbose {
                publication.logger.debug("Published: \(thisGroupId): \(thisObjectId)")
            }
            publication.publishFailure.store(false, ordering: .releasing)
        default:
            publication.logger.warning("Failed to publish object: \(status)")
            publication.publishFailure.store(true, ordering: .releasing)
            return
        }

        // Update IDs on success.
        publication.currentGroupId = thisGroupId
        publication.currentObjectId = thisObjectId
        publication.sequence += 1

        // Metrics.
        guard let measurement = publication.measurement else { return }
        let bytes = status.1
        let sent: Date? = publication.granularMetrics ? Date.now : nil
        Task(priority: .utility) {
            await measurement.measurement.sentFrame(bytes: UInt64(bytes),
                                                    timestamp: presentationDate.timeIntervalSince1970,
                                                    age: sent?.timeIntervalSince(presentationDate) ?? nil,
                                                    metricsTimestamp: sent)
        }
    }

    // MARK: - Initialization

    required init(profile: Profile,
                  config: VideoCodecConfig,
                  metricsSubmitter: MetricsSubmitter?,
                  reliable: Bool,
                  granularMetrics: Bool,
                  encoder: VideoEncoder,
                  device: AVCaptureDevice,
                  endpointId: String,
                  relayId: String,
                  stagger: Bool,
                  verbose: Bool,
                  keyFrameOnUpdate: Bool,
                  sframeContext: SendSFrameContext?,
                  mediaInterop: Bool,
                  sink: MoQSink) throws {
        // Store configuration (previously from Publication base class)
        self.profile = profile
        guard let defaultPriority = profile.priorities?.first,
              let defaultTTL = profile.expiry?.first else {
            throw "Missing expected profile values"
        }
        self.defaultPriority = UInt8(clamping: defaultPriority)
        self.defaultTTL = UInt16(clamping: defaultTTL)

        // Setup track measurement (previously from Publication base class)
        if let metricsSubmitter = metricsSubmitter {
            let trackMeasurement = TrackMeasurement(type: .publish,
                                                    endpointId: endpointId,
                                                    relayId: relayId,
                                                    namespace: profile.namespace.joined())
            self.trackMeasurement = .init(measurement: trackMeasurement, submitter: metricsSubmitter)
        } else {
            self.trackMeasurement = nil
        }

        // Store the sink
        self.sink = sink

        let namespace = profile.namespace.joined()
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
        self.stagger = stagger
        self.verbose = verbose
        self.keyFrameOnUpdate = keyFrameOnUpdate
        self.sframeContext = sframeContext
        self.mediaInterop = mediaInterop
        self.logger.info("Registered H264 publication for namespace \(namespace)")

        // Set self as delegate to receive callbacks from the sink
        self.sink.delegate = self

        let userData = Unmanaged.passUnretained(self).toOpaque()
        self.encoder.setCallback(onEncodedData, userData: userData)
    }

    // MARK: - Publishing

    internal func publish(groupId: UInt64,
                          objectId: UInt64,
                          data: Data,
                          priority: UnsafePointer<UInt8>?,
                          ttl: UnsafePointer<UInt16>?,
                          extensions: HeaderExtensions?,
                          immutableExtensions: HeaderExtensions?) -> QPublishObjectStatus {
        let headers = QObjectHeaders(groupId: groupId,
                                     objectId: objectId,
                                     payloadLength: UInt64(data.count),
                                     priority: priority,
                                     ttl: ttl)
        return self.sink.publishObject(headers, data: data, extensions: extensions, immutableExtensions: immutableExtensions)
    }

    // MARK: - Priority/TTL Helpers (previously from Publication base class)

    /// Retrieve the priority value from this publication's priority array at
    /// the given index, if one exists.
    /// - Parameter index: Offset into the priority array.
    /// - Returns: Priority value, or the default value.
    public func getPriority(_ index: Int) -> UInt8 {
        guard let priorities = profile.priorities,
              index < priorities.count,
              priorities[index] <= UInt8.max,
              priorities[index] >= UInt8.min else {
            return self.defaultPriority
        }
        return UInt8(priorities[index])
    }

    /// Retrieve the TTL / expiry value from this publication's expiry array at
    /// the given index, if one exists.
    /// - Parameter index: Offset into the expiry array.
    /// - Returns: TTL/Expiry value, or the default value.
    public func getTTL(_ index: Int) -> UInt16 {
        guard let ttls = profile.expiry,
              index < ttls.count,
              ttls[index] <= UInt16.max,
              ttls[index] >= UInt16.min else {
            return self.defaultTTL
        }
        return UInt16(ttls[index])
    }

    deinit {
        self.logger.debug("Deinit")
    }

    // MARK: - MoQSinkDelegate

    func sinkStatusChanged(_ status: QPublishTrackHandlerStatus) {
        self.logger.info("[\(self.profile.namespace.joined())] Status changed to: \(status)")
        if (status == .subscriptionUpdated && self.keyFrameOnUpdate) || status == .newGroupRequested {
            self.generateKeyFrame.store(true, ordering: .releasing)
        }
    }

    func sinkMetricsSampled(_ metrics: QPublishTrackMetrics) {
        if let measurement = self.trackMeasurement?.measurement {
            Task(priority: .utility) {
                await measurement.record(metrics)
            }
        }
    }

    /// Backwards compat for older tests invoking libquicr callbacks directly.
    func metricsSampled(_ metrics: QPublishTrackMetrics) {
        self.sinkMetricsSampled(metrics)
    }

    // MARK: - FrameListener

    /// This callback fires when a video frame arrives.
    func onFrame(_ sampleBuffer: CMSampleBuffer,
                 timestamp: Date) {
        // Configure FPS.
        let maxRate = self.device.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate
        if self.encoder.frameRate == nil {
            self.encoder.frameRate = maxRate
        } else {
            if self.encoder.frameRate != maxRate {
                self.logger.warning("Frame rate mismatch? Had: \(String(describing: self.encoder.frameRate)), got: \(String(describing: maxRate))")
            }
        }

        // If we're not in a state to be publishing, don't go any further.
        guard self.canPublish() else {
            self.logger.debug("Didn't encode due to publication status: \(self.getStatus())")
            return
        }

        // Stagger the publication's start time by its height in ms.
        if self.stagger {
            guard let startTime = self.startTime else {
                self.startTime = timestamp
                return
            }
            let interval = timestamp.timeIntervalSince(startTime)
            guard interval > TimeInterval(self.codec!.height) / 1000.0 else {
                self.logger.debug("Dropping due to stagger")
                return
            }
        }

        // Should we be forcing a key frame?
        var keyFrame: Bool {
            // If the last publish failed, we need a key frame.
            guard !self.publishFailure.load(ordering: .acquiring) else {
                self.logger.debug("Forcing key frame - last time didn't publish")
                // Consume any existing request.
                _ = self.generateKeyFrame.compareExchange(expected: true,
                                                          desired: false,
                                                          ordering: .acquiringAndReleasing)
                return true
            }

            // If we asked for key frame, make one (subscribe update).
            let (generate, _) = self.generateKeyFrame.compareExchange(expected: true,
                                                                      desired: false,
                                                                      ordering: .acquiringAndReleasing)
            if generate {
                self.logger.debug("Forcing key frame - subscribe update")
            }
            return generate
        }

        // Encode.
        do {
            try encoder.write(sample: sampleBuffer, timestamp: timestamp, forceKeyFrame: keyFrame)
        } catch {
            self.logger.error("Failed to encode frame: \(error.localizedDescription)")
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

    // MARK: - Parameter Sets

    /// Returns the parameter sets contained within the sample's format, if any.
    /// - Parameter sample The sample to extract parameter sets from.
    /// - Returns Array of buffer pointers referencing the data. This is only safe to use during the lifetime of sample.
    private func handleParameterSets(sample: CMSampleBuffer) throws -> [UnsafeRawBufferPointer] {
        // Get number of parameter sets.
        var sets: Int = 0
        try OSStatusError.checked("Get number of SPS/PPS") {
            switch self.codec?.codec {
            case .h264:
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(sample.formatDescription!,
                                                                   parameterSetIndex: 0,
                                                                   parameterSetPointerOut: nil,
                                                                   parameterSetSizeOut: nil,
                                                                   parameterSetCountOut: &sets,
                                                                   nalUnitHeaderLengthOut: nil)
            case .hevc:
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(sample.formatDescription!,
                                                                   parameterSetIndex: 0,
                                                                   parameterSetPointerOut: nil,
                                                                   parameterSetSizeOut: nil,
                                                                   parameterSetCountOut: &sets,
                                                                   nalUnitHeaderLengthOut: nil)
            default:
                1
            }
        }

        // Get actual parameter sets.
        var parameterSetPointers: [UnsafeRawBufferPointer] = []
        for parameterSetIndex in 0...sets-1 {
            var parameterSet: UnsafePointer<UInt8>?
            var parameterSize: Int = 0
            var naluSizeOut: Int32 = 0
            try OSStatusError.checked("Get SPS/PPS data") {
                switch self.codec?.codec {
                case .h264:
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(sample.formatDescription!,
                                                                       parameterSetIndex: parameterSetIndex,
                                                                       parameterSetPointerOut: &parameterSet,
                                                                       parameterSetSizeOut: &parameterSize,
                                                                       parameterSetCountOut: nil,
                                                                       nalUnitHeaderLengthOut: &naluSizeOut)
                case .hevc:
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(sample.formatDescription!,
                                                                       parameterSetIndex: parameterSetIndex,
                                                                       parameterSetPointerOut: &parameterSet,
                                                                       parameterSetSizeOut: &parameterSize,
                                                                       parameterSetCountOut: nil,
                                                                       nalUnitHeaderLengthOut: &naluSizeOut)
                default:
                    1
                }
            }
            guard naluSizeOut == self.startCode.count else { throw "Unexpected start code length?" }
            parameterSetPointers.append(.init(start: parameterSet!, count: parameterSize))
        }
        return parameterSetPointers
    }
}
