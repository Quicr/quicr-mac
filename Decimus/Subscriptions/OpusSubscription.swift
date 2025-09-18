// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SFrame
import Synchronization

class OpusSubscription: Subscription {
    private static let logger = DecimusLogger(OpusSubscription.self)

    struct Config {
        let adaptive: Bool
        let mediaInterop: Bool
    }

    private let profile: Profile
    private let engine: DecimusAudioEngine
    private let measurement: MeasurementRegistration<OpusSubscriptionMeasurement>?
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
    private let activeSpeakerStats: ActiveSpeakerStats?
    private let sframeContext: SFrameContext?
    private let maxPlcThreshold: Int
    private let playoutBufferTime: TimeInterval
    private let slidingWindowTime: TimeInterval
    private let config: Config

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
         activeSpeakerStats: ActiveSpeakerStats?,
         sframeContext: SFrameContext?,
         maxPlcThreshold: Int,
         playoutBufferTime: TimeInterval,
         slidingWindowTime: TimeInterval,
         config: Config,
         statusChanged: @escaping StatusCallback) throws {
        self.profile = profile
        self.engine = engine
        self.metricsSubmitter = submitter
        if let submitter = submitter {
            let measurement = OpusSubscriptionMeasurement(namespace: profile.namespace.joined())
            self.measurement = .init(measurement: measurement, submitter: submitter)
        } else {
            self.measurement = nil
        }
        self.jitterDepth = jitterDepth
        self.jitterMax = jitterMax
        self.opusWindowSize = opusWindowSize
        self.reliable = reliable
        self.granularMetrics = granularMetrics
        self.useNewJitterBuffer = useNewJitterBuffer
        self.cleanupTimer = cleanupTime
        self.activeSpeakerStats = activeSpeakerStats
        self.sframeContext = sframeContext
        self.maxPlcThreshold = maxPlcThreshold
        self.playoutBufferTime = playoutBufferTime
        self.slidingWindowTime = slidingWindowTime
        self.config = config

        // Create the actual audio handler upfront.
        let config = AudioHandler.Config(jitterDepth: self.jitterDepth,
                                         jitterMax: self.jitterMax,
                                         opusWindowSize: self.opusWindowSize,
                                         granularMetrics: self.granularMetrics,
                                         useNewJitterBuffer: self.useNewJitterBuffer,
                                         maxPlcThreshold: self.maxPlcThreshold,
                                         playoutBufferTime: self.playoutBufferTime,
                                         slidingWindowTime: self.slidingWindowTime,
                                         adaptive: self.config.adaptive)
        self.handler = try .init(.init(identifier: self.profile.namespace.joined(),
                                       engine: self.engine,
                                       decoder: LibOpusDecoder(format: DecimusAudioEngine.format),
                                       measurement: self.measurement,
                                       metricsSubmitter: self.metricsSubmitter,
                                       config: config))
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

        Self.logger.info("Subscribed to OPUS stream")
    }

    deinit {
        Self.logger.debug("Deinit")
    }

    override func objectReceived(_ objectHeaders: QObjectHeaders,
                                 data: Data,
                                 extensions: HeaderExtensions?,
                                 immutableExtensions: HeaderExtensions?) {
        let now: Date = .now
        self.lastUpdateTime.withLock { $0 = now }

        // Metrics.
        let date: Date? = self.granularMetrics ? now : nil

        guard let extensions = extensions else {
            Self.logger.warning("Missing expected extensions")
            return
        }

        let sequence: UInt64
        let timestamp: Date
        do {
            let (seq, time) = try self.parseExtensionHeaders(extensions)
            sequence = seq ?? objectHeaders.groupId
            timestamp = time
        } catch {
            Self.logger.error("Failed to parse extensions: \(error.localizedDescription)")
            return
        }

        // Active speaker metric.
        if let activeSpeakerStats = self.activeSpeakerStats,
           let participantId = try? extensions.getHeader(.participantId),
           case .participantId(let id) = participantId {
            Task(priority: .utility) {
                await activeSpeakerStats.audioDetected(id, when: now)
            }
        }

        // Unprotect.
        let unprotected: Data
        if let sframeContext {
            do {
                unprotected = try sframeContext.mutex.withLock { try $0.unprotect(ciphertext: data) }
            } catch {
                Self.logger.error("Failed to unprotect: \(error.localizedDescription)")
                return
            }
        } else {
            unprotected = data
        }

        // TODO: Handle sequence rollover.
        if sequence > self.seq {
            let missing = sequence - self.seq - 1
            let currentSeq = self.seq
            if let measurement = measurement {
                Task(priority: .utility) {
                    await measurement.measurement.receivedBytes(received: UInt(data.count), timestamp: date)
                    if missing > 0 {
                        Self.logger.warning("LOSS! \(missing) packets. Had: \(currentSeq), got: \(sequence)")
                        await measurement.measurement.missingSeq(missingCount: UInt64(missing), timestamp: date)
                    }
                }
            }
            self.seq = sequence
        }

        // Do we need to create the handler?
        let handler: AudioHandler
        do {
            handler = try self.handler.withLock { lockedHandler in
                guard let handler = lockedHandler else {
                    let config = AudioHandler.Config(jitterDepth: self.jitterDepth,
                                                     jitterMax: self.jitterMax,
                                                     opusWindowSize: self.opusWindowSize,
                                                     granularMetrics: self.granularMetrics,
                                                     useNewJitterBuffer: self.useNewJitterBuffer,
                                                     maxPlcThreshold: self.maxPlcThreshold,
                                                     playoutBufferTime: self.playoutBufferTime,
                                                     slidingWindowTime: self.slidingWindowTime,
                                                     adaptive: self.config.adaptive)
                    let handler = try AudioHandler(identifier: self.profile.namespace.joined(),
                                                   engine: self.engine,
                                                   decoder: LibOpusDecoder(format: DecimusAudioEngine.format),
                                                   measurement: self.measurement,
                                                   metricsSubmitter: self.metricsSubmitter,
                                                   config: config)
                    lockedHandler = handler
                    return handler
                }
                return handler
            }
        } catch {
            Self.logger.error("Failed to recreate audio handler")
            return
        }

        do {
            try handler.submitEncodedAudio(data: unprotected,
                                           sequence: sequence,
                                           date: now,
                                           timestamp: timestamp)
        } catch {
            Self.logger.error("Failed to handle encoded audio: \(error.localizedDescription)")
        }
    }

    private func parseExtensionHeaders(_ extensions: HeaderExtensions) throws -> (UInt64?, Date) {
        let sequence: UInt64?
        let timestamp: Date
        if self.config.mediaInterop {
            guard let data = try? extensions.getHeader(.audioOpusBitstreamData),
                  case .audioOpusBitstreamData(let metadata) = data else {
                throw "Missing expected interop extension"
            }
            sequence = metadata.seqId.value
            timestamp = .init(timeIntervalSince1970: TimeInterval(metadata.wallClock.value) / 1000)
        } else {
            if let data = try? extensions.getHeader(.sequenceNumber),
               case .sequenceNumber(let seq) = data {
                sequence = seq
            } else {
                sequence = nil
            }

            // Timestamp.
            guard let data = try? extensions.getHeader(.captureTimestamp),
                  case .captureTimestamp(let captureTimestamp) = data else {
                throw "Bad timestamp header"
            }
            timestamp = captureTimestamp
        }
        return (sequence, timestamp)
    }
}
