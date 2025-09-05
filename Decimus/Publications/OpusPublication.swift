// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import AVFAudio
import CoreAudio
import Accelerate
import Synchronization

class OpusPublication: Publication, AudioPublication {
    private static let logger = DecimusLogger(OpusPublication.self)
    private static let silence: Int = 127

    private let encoder: LibOpusEncoder
    private let measurement: MeasurementRegistration<OpusPublicationMeasurement>?
    private let opusWindowSize: OpusWindowSize
    private let reliable: Bool
    private let granularMetrics: Bool
    private let engine: DecimusAudioEngine
    private var encodeTask: Task<(), Never>?
    private let pcm: AVAudioPCMBuffer
    private let windowFrames: AVAudioFrameCount
    private let startingGroupId: UInt64
    private var currentGroupId: UInt64
    private var currentObjectId: UInt64 = 0
    private let participantId: ParticipantId
    private let publish: Atomic<Bool>
    private let incrementing: Incrementing
    private let sframeContext: SendSFrameContext?
    private let mediaInterop: Bool

    init(profile: Profile,
         participantId: ParticipantId,
         metricsSubmitter: MetricsSubmitter?,
         opusWindowSize: OpusWindowSize,
         reliable: Bool,
         engine: DecimusAudioEngine,
         granularMetrics: Bool,
         config: AudioCodecConfig,
         endpointId: String,
         relayId: String,
         startActive: Bool,
         incrementing: Incrementing,
         sframeContext: SendSFrameContext?,
         mediaInterop: Bool,
         groupId: UInt64 = UInt64(Date.now.timeIntervalSince1970)) throws {
        self.engine = engine
        let namespace = profile.namespace.joined()
        if let metricsSubmitter = metricsSubmitter {
            self.measurement = .init(measurement: OpusPublicationMeasurement(namespace: namespace),
                                     submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.opusWindowSize = opusWindowSize
        self.reliable = reliable
        self.granularMetrics = granularMetrics
        self.incrementing = incrementing
        self.sframeContext = sframeContext
        self.mediaInterop = mediaInterop

        // Create a buffer to hold raw data waiting for encode.
        let format = DecimusAudioEngine.format
        self.windowFrames = AVAudioFrameCount(format.sampleRate * self.opusWindowSize.rawValue)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: self.windowFrames) else {
            throw "Failed to allocate PCM buffer"
        }
        self.pcm = pcm

        encoder = try .init(format: format, desiredWindowSize: opusWindowSize, bitrate: Int(config.bitrate))
        Self.logger.info("Created Opus Encoder")

        guard let defaultPriority = profile.priorities?.first,
              let defaultTTL = profile.expiry?.first else {
            throw "Missing expected profile values"
        }
        self.participantId = participantId
        self.publish = .init(startActive)
        self.startingGroupId = groupId
        self.currentGroupId = groupId

        try super.init(profile: profile,
                       trackMode: reliable ? .stream : .datagram,
                       defaultPriority: UInt8(clamping: defaultPriority),
                       defaultTTL: UInt16(clamping: defaultTTL),
                       submitter: metricsSubmitter,
                       endpointId: endpointId,
                       relayId: relayId,
                       logger: Self.logger)

        // Setup encode job.
        self.encodeTask = .init(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                if let self = self,
                   self.publish.load(ordering: .acquiring) {
                    do {
                        var encodePassCount = 0
                        while let data = try self.encode() {
                            encodePassCount += 1
                            self.publish(data: data.encodedData,
                                         extensions: data.extensions,
                                         decibel: data.decibelLevel)
                        }
                        if self.granularMetrics,
                           let measurement = self.measurement?.measurement {
                            let now = Date.now
                            Task(priority: .utility) {
                                await measurement.encode(encodePassCount, timestamp: now)
                            }
                        }
                    } catch {
                        Self.logger.error("Failed encode: \(error)")
                    }
                }
                try? await Task.sleep(for: .seconds(opusWindowSize.rawValue),
                                      tolerance: .seconds(opusWindowSize.rawValue / 2),
                                      clock: .continuous)
            }
        }

        Self.logger.info("Registered OPUS publication for namespace \(namespace)")
    }

    deinit {
        self.encodeTask?.cancel()
        Self.logger.debug("Deinit")
    }

    func togglePublishing(active: Bool) {
        self.publish.store(active, ordering: .releasing)
    }

    private func getExtensions(wallClock: Date, dequeuedTimestamp: AudioTimeStamp) throws -> HeaderExtensions {
        if self.mediaInterop {
            var extensions = HeaderExtensions()
            let metadata = AudioBitstreamData(seqId: self.currentGroupId,
                                              ptsTimestamp: dequeuedTimestamp.mHostTime,
                                              timebase: 1_000_000_000, sampleFreq: UInt64(self.pcm.format.sampleRate),
                                              numChannels: UInt64(self.pcm.format.channelCount),
                                              duration: UInt64(self.opusWindowSize.rawValue * 1_000_000_000.0),
                                              wallClock: UInt64(wallClock.timeIntervalSince1970 * 1000))
            try extensions.setHeader(.audioOpusBitstreamData(metadata))
            return extensions
        } else {
            let loc = LowOverheadContainer(timestamp: wallClock, sequence: self.currentGroupId)
            return loc.extensions
        }
    }

    private func publish(data: Data, extensions: HeaderExtensions, decibel: Int) {
        if let measurement = self.measurement {
            let now: Date? = granularMetrics ? .now : nil
            Task(priority: .utility) {
                await measurement.measurement.publishedBytes(sentBytes: data.count, timestamp: now)
            }
        }

        guard self.shouldPublish() else {
            Self.logger.warning("Not published due to status: \(self.getStatus())")
            return
        }

        var extensions = extensions

        var priority = self.getPriority(0)
        var ttl = self.getTTL(0)
        let adjusted = UInt8(abs(decibel))
        let mask: UInt8 = adjusted == Self.silence ? 0b00000000 : 0b10000000
        let energyLevelValue = adjusted | mask
        extensions[AppHeaderRegistry.energyLevel.rawValue] = Data([energyLevelValue])
        var participantId = self.participantId.aggregate
        extensions[AppHeaderRegistry.participantId.rawValue] = Data(bytes: &participantId,
                                                                    count: MemoryLayout<UInt32>.size)

        let protected: Data
        if let sframeContext {
            do {
                protected = try sframeContext.context.mutex.withLock { locked in
                    try locked.protect(epochId: sframeContext.currentEpoch,
                                       senderId: sframeContext.senderId,
                                       plaintext: data)
                }
            } catch {
                Self.logger.error("Failed to protect: \(error.localizedDescription)")
                return
            }
        } else {
            protected = data
        }
        let published = self.publish(data: protected, priority: &priority, ttl: &ttl, extensions: extensions)
        switch published {
        case .ok:
            switch self.incrementing {
            case .group:
                self.currentGroupId += 1
            case .object:
                self.currentObjectId += 1
            }
        default:
            Self.logger.warning("Failed to publish: \(published)")
        }
    }

    private func publish(data: Data,
                         priority: UnsafePointer<UInt8>?,
                         ttl: UnsafePointer<UInt16>?,
                         extensions: HeaderExtensions) -> QPublishObjectStatus {
        let headers = QObjectHeaders(groupId: self.currentGroupId,
                                     objectId: 0,
                                     payloadLength: UInt64(data.count),
                                     priority: priority,
                                     ttl: ttl)
        return self.publishObject(headers, data: data, extensions: extensions)
    }

    struct EncodeResult {
        let encodedData: Data
        let decibelLevel: Int
        let extensions: HeaderExtensions
    }

    private func encode() throws -> EncodeResult? {
        guard let buffer = self.engine.microphoneBuffer else {
            #if os(macOS)
            return nil
            #else
            throw "No Audio Input"
            #endif
        }

        // Are there enough frames available to fill an opus window?
        let available = buffer.peek()
        guard available.frames >= self.windowFrames else { return nil }

        // Dequeue a window size worth of data.
        self.pcm.frameLength = self.windowFrames
        let dequeued = buffer.dequeue(frames: self.windowFrames, buffer: &self.pcm.mutableAudioBufferList.pointee)
        self.pcm.frameLength = dequeued.frames
        guard dequeued.frames == self.windowFrames else {
            Self.logger.warning("Dequeue only got: \(dequeued.frames)/\(self.windowFrames)")
            return nil
        }

        // Encode this data.
        let encoded = try self.encoder.write(data: self.pcm)
        // Get absolute time.
        let wallClock = hostToDate(dequeued.timestamp.mHostTime)
        // Get audio level.
        let decibel = try self.getAudioLevel(self.pcm)

        let extensions = try self.getExtensions(wallClock: wallClock, dequeuedTimestamp: dequeued.timestamp)
        return .init(encodedData: encoded, decibelLevel: decibel, extensions: extensions)
    }

    private func getAudioLevel(_ buffer: AVAudioPCMBuffer) throws -> Int {
        guard let data = buffer.floatChannelData else {
            throw "Missing float data"
        }
        let channels = Int(buffer.format.channelCount)
        var rms: Float = 0.0
        for channel in 0..<channels {
            var channelRms: Float = 0.0
            vDSP_rmsqv(data[channel], 1, &channelRms, vDSP_Length(buffer.frameLength))
            rms += abs(channelRms)
        }
        rms /= Float(channels)
        let minAudioLevel: Float = -127
        let maxAudioLevel: Float = 0
        guard rms > 0 else {
            return Int(minAudioLevel)
        }
        var decibel = 20 * log10(rms)
        decibel = min(decibel, maxAudioLevel)
        decibel = max(decibel, minAudioLevel)
        return Int(decibel.rounded())
    }
}
