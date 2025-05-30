// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SFrame
import Synchronization

class OpusSubscription: Subscription {
    private static let logger = DecimusLogger(OpusSubscription.self)

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

        // Create the actual audio handler upfront.
        let config = AudioHandler.Config(jitterDepth: self.jitterDepth,
                                         jitterMax: self.jitterMax,
                                         opusWindowSize: self.opusWindowSize,
                                         granularMetrics: self.granularMetrics,
                                         useNewJitterBuffer: self.useNewJitterBuffer,
                                         maxPlcThreshold: self.maxPlcThreshold,
                                         playoutBufferTime: self.playoutBufferTime,
                                         slidingWindowTime: self.slidingWindowTime)
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

    override func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        let now: Date = .now
        self.lastUpdateTime.withLock { $0 = now }

        // Metrics.
        let date: Date? = self.granularMetrics ? now : nil

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

        guard let extensions = extensions,
              let loc = try? LowOverheadContainer(from: extensions) else {
            Self.logger.warning("Missing expected LOC headers")
            return
        }

        // TODO: Handle sequence rollover.
        let sequence = loc.sequence ?? objectHeaders.objectId
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
                                                     slidingWindowTime: self.slidingWindowTime)
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

        if let activeSpeakerStats = self.activeSpeakerStats,
           let participantId = loc.get(key: OpusPublication.participantIdKey) {
            Task(priority: .utility) {
                let participantId = participantId.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                await activeSpeakerStats.audioDetected(.init(participantId), when: now)
            }
        }

        do {
            try handler.submitEncodedAudio(data: unprotected,
                                           sequence: sequence,
                                           date: now,
                                           timestamp: loc.timestamp)
        } catch {
            Self.logger.error("Failed to handle encoded audio: \(error.localizedDescription)")
        }
    }
}
