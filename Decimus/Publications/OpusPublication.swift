// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import AVFAudio
import CoreAudio
import Accelerate
import Synchronization

class OpusPublication: Publication, AudioPublication {
    enum Incrementing {
        case group
        case object
    }

    private static let logger = DecimusLogger(OpusPublication.self)
    static let energyLevelKey: NSNumber = 6
    static let participantIdKey: NSNumber = 8
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
                            self.publish(data: data.encodedData, timestamp: data.timestamp, decibel: data.decibelLevel)
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

    private func publish(data: Data, timestamp: Date, decibel: Int) {
        if let measurement = self.measurement {
            let now: Date? = granularMetrics ? .now : nil
            Task(priority: .utility) {
                await measurement.measurement.publishedBytes(sentBytes: data.count, timestamp: now)
            }
        }

        let status = self.getStatus()
        guard status == .ok || status == .subscriptionUpdated else {
            Self.logger.warning("Not published due to status: \(status)")
            return
        }
        var priority = self.getPriority(0)
        var ttl = self.getTTL(0)
        let sequence = switch incrementing {
        case .group:
            self.currentGroupId - self.startingGroupId
        case .object:
            self.currentObjectId
        }
        let loc = LowOverheadContainer(timestamp: timestamp, sequence: sequence)
        let adjusted = UInt8(abs(decibel))
        let mask: UInt8 = adjusted == Self.silence ? 0b00000000 : 0b10000000
        let energyLevelValue = adjusted | mask
        loc.add(key: Self.energyLevelKey, value: Data([energyLevelValue]))
        var participantId = self.participantId.aggregate
        loc.add(key: Self.participantIdKey, value: Data(bytes: &participantId, count: MemoryLayout<UInt32>.size))

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
        let published = self.publish(data: protected, priority: &priority, ttl: &ttl, loc: loc)
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
                         loc: LowOverheadContainer) -> QPublishObjectStatus {
        let headers = QObjectHeaders(groupId: self.currentGroupId,
                                     objectId: self.currentObjectId,
                                     payloadLength: UInt64(data.count),
                                     priority: priority,
                                     ttl: ttl)
        return self.publishObject(headers, data: data, extensions: loc.extensions)
    }

    struct EncodeResult {
        let encodedData: Data
        let timestamp: Date
        let decibelLevel: Int
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
        let wallClock = try hostToDate(dequeued.timestamp.mHostTime)

        // Get audio level.
        let decibel = try self.getAudioLevel(self.pcm)

        // Encode this data.
        return .init(encodedData: encoded, timestamp: wallClock, decibelLevel: decibel)
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
