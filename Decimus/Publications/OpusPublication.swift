// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import AVFAudio
import AVFoundation
import CoreAudio
import os
import Accelerate

class OpusPublication: Publication {
    private static let logger = DecimusLogger(OpusPublication.self)
    static let energyLevelKey = NSNumber(integerLiteral: 3)
    static let participantIdKey = NSNumber(integerLiteral: 4)
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
    private var currentGroupId: UInt64?
    private let bootDate: Date
    private let participantId: ParticipantId

    init(profile: Profile,
         participantId: ParticipantId,
         metricsSubmitter: MetricsSubmitter?,
         opusWindowSize: OpusWindowSize,
         reliable: Bool,
         engine: DecimusAudioEngine,
         granularMetrics: Bool,
         config: AudioCodecConfig,
         endpointId: String,
         relayId: String) throws {
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
        self.bootDate = Date.now.addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        self.participantId = participantId

        try super.init(profile: profile,
                       trackMode: reliable ? .streamPerTrack : .datagram,
                       defaultPriority: UInt8(clamping: defaultPriority),
                       defaultTTL: UInt16(clamping: defaultTTL),
                       submitter: metricsSubmitter,
                       endpointId: endpointId,
                       relayId: relayId)

        // Setup encode job.
        self.encodeTask = .init(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                if let self = self {
                    do {
                        var encodePassCount = 0
                        while let data = try self.encode() {
                            encodePassCount += 1
                            self.publish(data: data.0, timestamp: data.1, decibel: data.2)
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

    private func publish(data: Data, timestamp: Date, decibel: Int) {
        if let measurement = self.measurement {
            let now: Date? = granularMetrics ? .now : nil
            Task(priority: .utility) {
                await measurement.measurement.publishedBytes(sentBytes: data.count, timestamp: now)
            }
        }

        guard self.publish.load(ordering: .acquiring) else {
            Self.logger.warning("Not published due to status")
            return
        }
        var priority = self.getPriority(0)
        var ttl = self.getTTL(0)
        if self.currentGroupId == nil {
            self.currentGroupId = UInt64(Date.now.timeIntervalSince1970)
        }
        let loc = LowOverheadContainer(timestamp: timestamp, sequence: self.currentGroupId!)
        let adjusted = UInt8(abs(decibel))
        let mask: UInt8 = adjusted == Self.silence ? 0b00000000 : 0b10000000
        let energyLevelValue = adjusted | mask
        loc.add(key: Self.energyLevelKey, value: Data([energyLevelValue]))
        var endpointId = self.participantId
        loc.add(key: Self.participantIdKey, value: Data(bytes: &endpointId, count: MemoryLayout<UInt32>.size))
        let published = self.publish(data: data, priority: &priority, ttl: &ttl, loc: loc)
        switch published {
        case .ok:
            self.currentGroupId! += 1
            break
        default:
            Self.logger.warning("Failed to publish: \(published)")
        }
    }

    private func publish(data: Data,
                         priority: UnsafePointer<UInt8>?,
                         ttl: UnsafePointer<UInt16>?,
                         loc: LowOverheadContainer) -> QPublishObjectStatus {
        let headers = QObjectHeaders(groupId: self.currentGroupId!,
                                     objectId: 0,
                                     payloadLength: UInt64(data.count),
                                     priority: priority,
                                     ttl: ttl)
        return self.publishObject(headers, data: data, extensions: loc.extensions)
    }

    private func encode() throws -> (Data, Date, Int)? {
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
        let wallClock = try getAudioDate(dequeued.timestamp.mHostTime, bootDate: self.bootDate)

        // Get audio level.
        let decibel = try self.getAudioLevel(self.pcm)

        // Encode this data.
        return (encoded, wallClock, decibel)
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
        rms = rms / Float(channels)
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

func getAudioDate(_ hostTime: UInt64, bootDate: Date) throws -> Date {
    let nano: UInt64
    #if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
    nano = getAudioDateMac(hostTime)
    #else
    nano = try getAudioDateiOS(hostTime)
    #endif
    let nanoInterval = TimeInterval(nano) / 1_000_000_000
    return bootDate.addingTimeInterval(nanoInterval)
}

#if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
func getAudioDateMac(_ hostTime: UInt64) -> UInt64 {
    AudioConvertHostTimeToNanos(hostTime)
}
#endif

func getAudioDateiOS(_ hostTime: UInt64) throws -> UInt64 {
    // Get absolute time.
    var info = mach_timebase_info_data_t()
    let result = mach_timebase_info(&info)
    guard result == KERN_SUCCESS else {
        throw "Failed to get mach time"
    }
    let factor = TimeInterval(info.numer) / TimeInterval(info.denom)
    let ns = TimeInterval(hostTime) * factor
    return UInt64(ns)
}
