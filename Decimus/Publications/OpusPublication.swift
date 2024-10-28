// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import AVFAudio
import AVFoundation
import CoreAudio
import os

class OpusPublication: Publication {
    private static let logger = DecimusLogger(OpusPublication.self)

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

    init(profile: Profile,
         metricsSubmitter: MetricsSubmitter?,
         opusWindowSize: OpusWindowSize,
         reliable: Bool,
         engine: DecimusAudioEngine,
         granularMetrics: Bool,
         config: AudioCodecConfig,
         endpointId: String,
         relayId: String) throws {
        self.engine = engine
        let namespace = profile.namespace
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
                            self.publish(data: data.0, timestamp: data.1)
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

    private func publish(data: Data, timestamp: Date) {
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

    private func encode() throws -> (Data, Date)? {
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

        // Get absolute time.
        let nano = AudioConvertHostTimeToNanos(dequeued.timestamp.mHostTime)
        let nanoInterval = TimeInterval(nano) / 1_000_000_000
        let wallClock = self.bootDate.addingTimeInterval(nanoInterval)

        self.pcm.frameLength = dequeued.frames
        guard dequeued.frames == self.windowFrames else {
            Self.logger.warning("Dequeue only got: \(dequeued.frames)/\(self.windowFrames)")
            return nil
        }

        // Encode this data.
        return (try self.encoder.write(data: self.pcm), wallClock)
    }
}
