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
    private var currentGroupId: UInt64 = 0

    init(profile: Profile,
         metricsSubmitter: MetricsSubmitter?,
         opusWindowSize: OpusWindowSize,
         reliable: Bool,
         engine: DecimusAudioEngine,
         granularMetrics: Bool,
         config: AudioCodecConfig) throws {
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

        try super.init(profile: profile,
                       trackMode: reliable ? .streamPerTrack : .datagram,
                       defaultPriority: UInt8(profile.priorities?.first ?? 0),
                       defaultTTL: UInt32(profile.expiry?.first ?? 0))

        // Setup encode job.
        self.encodeTask = .init(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                do {
                    while let data = try self.encode() {
                        self.publish(data: data)
                    }
                } catch {
                    Self.logger.error("Failed encode: \(error)")
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

    private func publish(data: Data) {
        if let measurement = self.measurement {
            let now: Date? = granularMetrics ? .now : nil
            Task(priority: .utility) {
                await measurement.measurement.publishedBytes(sentBytes: data.count, timestamp: now)
            }
        }
        self.currentGroupId += 1
        let headers = QObjectHeaders(groupId: self.currentGroupId,
                                     objectId: 0,
                                     payloadLength: UInt64(data.count),
                                     priority: nil,
                                     ttl: nil)
        guard self.publish.load(ordering: .acquiring) else {
            Self.logger.warning("Not publishing due to status")
            return
        }
        let published = self.publishObject(headers, data: data, extensions: [:])
        switch published {
        case .ok:
            break
        default:
            Self.logger.warning("Failed to publish: \(published)")
        }
    }

    private func encode() throws -> Data? {
        guard let buffer = self.engine.microphoneBuffer else { throw "No Audio Input" }

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
        return try self.encoder.write(data: self.pcm)
    }

    func publish(_ flag: Bool) {}
}
