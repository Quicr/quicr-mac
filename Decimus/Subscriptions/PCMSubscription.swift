// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization
import AVFAudio

class PCMConverter: AudioDecoder {
    let decodedFormat: AVAudioFormat
    let originalFormat: AVAudioFormat
    private let logger = DecimusLogger(PCMConverter.self)
    private let converter: AVAudioConverter
    private let outputBuffer: AVAudioPCMBuffer

    init(decodedFormat: AVAudioFormat, originalFormat: AVAudioFormat) throws {
        self.decodedFormat = decodedFormat
        self.originalFormat = originalFormat
        // TODO: Maybe take window size.
        guard let converter = AVAudioConverter(from: originalFormat, to: decodedFormat),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: decodedFormat, frameCapacity: 960) else {
            throw "Unsupported"
        }
        self.converter = converter
        self.outputBuffer = outputBuffer
    }

    func write(data: Data) throws -> AVAudioPCMBuffer {
        var data = data
        return data.withUnsafeMutableBytes { bytes in
            var bufferList = AudioBufferList(mNumberBuffers: 1,
                                             mBuffers: .init(mNumberChannels: 1,
                                                             mDataByteSize: UInt32(bytes.count),
                                                             mData: bytes.baseAddress))
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: self.originalFormat,
                                               bufferListNoCopy: &bufferList,
                                               deallocator: .none)
            var nsError: NSError?
            self.converter.convert(to: self.outputBuffer,
                                   error: &nsError) { packets, status in
                guard inputBuffer?.frameLength == packets else {
                    self.logger.error("mismatch")
                    status.pointee = .noDataNow
                    return inputBuffer
                }
                status.pointee = .haveData
                return inputBuffer
            }
            if let nsError {
                self.logger.error("ALaw PCM Conversion Failed: \(nsError.localizedDescription)")
            }
            return self.outputBuffer
        }
    }

    func frames(data: Data) throws -> AVAudioFrameCount {
        fatalError()
    }

    func plc(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        fatalError()
    }
}

class PCMSubscription: Subscription {
    private static let logger = DecimusLogger(PCMSubscription.self)

    private let profile: Profile
    private let engine: DecimusAudioEngine
    // private let measurement: MeasurementRegistration<OpusSubscriptionMeasurement>?
    private let reliable: Bool
    private let granularMetrics: Bool
    private var seq: UInt64 = 0
    private let handler: Mutex<AudioHandler?>
    private var cleanupTask: Task<(), Never>?
    private let cleanupTimer: TimeInterval
    private let lastUpdateTime = Mutex<Date?>(nil)
    private let jitterDepth: TimeInterval
    private let jitterMax: TimeInterval
    private let opusWindowSize: OpusWindowSize
    private let metricsSubmitter: MetricsSubmitter?
    private let useNewJitterBuffer: Bool
    private let fullTrackName: FullTrackName
    private let originalFormat: AVAudioFormat

    init(profile: Profile,
         engine: DecimusAudioEngine,
         submitter: MetricsSubmitter?,
         jitterDepth: TimeInterval,
         jitterMax: TimeInterval,
         opusWindowSize: OpusWindowSize,
         reliable: Bool,
         granularMetrics: Bool,
         endpointId: String,
         relayId: String,
         useNewJitterBuffer: Bool,
         cleanupTime: TimeInterval,
         statusChanged: @escaping StatusCallback) throws {
        self.profile = profile
        self.engine = engine
        self.metricsSubmitter = submitter
        self.jitterDepth = jitterDepth
        self.jitterMax = jitterMax
        self.opusWindowSize = opusWindowSize
        self.reliable = reliable
        self.granularMetrics = granularMetrics
        self.useNewJitterBuffer = useNewJitterBuffer
        self.cleanupTimer = cleanupTime

        // Original PCM format.
        var asbd = AudioStreamBasicDescription(mSampleRate: 16000,
                                               mFormatID: kAudioFormatALaw,
                                               mFormatFlags: 0,
                                               mBytesPerPacket: 1,
                                               mFramesPerPacket: 1,
                                               mBytesPerFrame: 1,
                                               mChannelsPerFrame: 1,
                                               mBitsPerChannel: 8,
                                               mReserved: 0)
        self.originalFormat = AVAudioFormat(streamDescription: &asbd)!

        // Create the actual audio handler upfront.
        self.handler = try .init(.init(identifier: self.profile.namespace.joined(),
                                       engine: self.engine,
                                       decoder: PCMConverter(decodedFormat: DecimusAudioEngine.format,
                                                             originalFormat: self.originalFormat),
                                       measurement: nil,
                                       jitterDepth: self.jitterDepth,
                                       jitterMax: self.jitterMax,
                                       opusWindowSize: self.opusWindowSize,
                                       granularMetrics: self.granularMetrics,
                                       useNewJitterBuffer: self.useNewJitterBuffer,
                                       metricsSubmitter: self.metricsSubmitter))
        let fullTrackName = try profile.getFullTrackName()
        self.fullTrackName = fullTrackName
        try super.init(profile: profile,
                       endpointId: endpointId,
                       relayId: relayId,
                       metricsSubmitter: submitter,
                       priority: 0,
                       groupOrder: .originalPublisherOrder,
                       filterType: .latestObject,
                       statusCallback: statusChanged)

        // Make task for cleaning up audio handlers.
        self.cleanupTask = .init(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let sleepTimer: TimeInterval
                if let self = self {
                    sleepTimer = self.cleanupTimer
                    self.lastUpdateTime.withLock { lockedUpdateTime in
                        guard let lastUpdateTime = lockedUpdateTime else { return }
                        if Date.now.timeIntervalSince(lastUpdateTime) >= self.cleanupTimer {
                            lockedUpdateTime = nil
                            self.handler.clear()
                        }
                    }
                } else {
                    return
                }
                try? await Task.sleep(for: .seconds(sleepTimer),
                                      tolerance: .seconds(sleepTimer),
                                      clock: .continuous)
            }
        }

        Self.logger.info("Subscribed to PCM stream")
    }

    deinit {
        Self.logger.debug("Deinit")
    }

    override func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        let now: Date = .now
        self.lastUpdateTime.withLock { $0 = now }

        // Metrics.
        let date: Date? = self.granularMetrics ? now : nil

        // TODO: Handle sequence rollover.
        if objectHeaders.objectId > self.seq {
            let missing = objectHeaders.objectId - self.seq - 1
            let currentSeq = self.seq
            self.seq = objectHeaders.objectId
        }

        // Do we need to create the handler?
        let handler: AudioHandler
        do {
            handler = try self.handler.withLock { lockedHandler in
                guard let handler = lockedHandler else {
                    let handler = try AudioHandler(identifier: self.profile.namespace.joined(),
                                                   engine: self.engine,
                                                   decoder: PCMConverter(decodedFormat: DecimusAudioEngine.format,
                                                                         originalFormat: self.originalFormat),
                                                   measurement: nil,
                                                   jitterDepth: self.jitterDepth,
                                                   jitterMax: self.jitterMax,
                                                   opusWindowSize: self.opusWindowSize,
                                                   granularMetrics: self.granularMetrics,
                                                   useNewJitterBuffer: self.useNewJitterBuffer,
                                                   metricsSubmitter: self.metricsSubmitter)
                    lockedHandler = handler
                    return handler
                }
                return handler
            }
        } catch {
            Self.logger.error("Failed to recreate audio handler")
            return
        }

        guard let extensions = extensions,
              let loc = try? LowOverheadContainer(from: extensions) else {
            Self.logger.warning("Missing expected LOC headers")
            return
        }
        do {
            try handler.submitEncodedAudio(data: data,
                                           sequence: objectHeaders.objectId,
                                           date: now,
                                           timestamp: loc.timestamp)
        } catch {
            Self.logger.error("Failed to handle encoded audio: \(error.localizedDescription)")
        }
    }
}
