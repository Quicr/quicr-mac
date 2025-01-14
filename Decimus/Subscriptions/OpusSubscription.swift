// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import os

class OpusSubscription: Subscription {
    private static let logger = DecimusLogger(OpusSubscription.self)

    private let profile: Profile
    private let engine: DecimusAudioEngine
    private let measurement: MeasurementRegistration<OpusSubscriptionMeasurement>?
    private let reliable: Bool
    private let granularMetrics: Bool
    private var seq: UInt64 = 0
    private let handlerLock = OSAllocatedUnfairLock()
    private var handler: OpusHandler?
    private var cleanupTask: Task<(), Never>?
    private let cleanupTimer: TimeInterval = 1.5
    private var lastUpdateTime: Date?
    private let jitterDepth: TimeInterval
    private let jitterMax: TimeInterval
    private let opusWindowSize: OpusWindowSize
    private let metricsSubmitter: MetricsSubmitter?
    private let useNewJitterBuffer: Bool
    private let fullTrackName: FullTrackName

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

        // Create the actual audio handler upfront.
        self.handler = try .init(identifier: self.profile.namespace.joined(),
                                 engine: self.engine,
                                 measurement: self.measurement,
                                 jitterDepth: self.jitterDepth,
                                 jitterMax: self.jitterMax,
                                 opusWindowSize: self.opusWindowSize,
                                 granularMetrics: self.granularMetrics,
                                 useNewJitterBuffer: self.useNewJitterBuffer,
                                 metricsSubmitter: self.metricsSubmitter)
        let fullTrackName = try profile.getFullTrackName()
        self.fullTrackName = fullTrackName
        try super.init(profile: profile,
                       endpointId: endpointId,
                       relayId: relayId,
                       metricsSubmitter: submitter,
                       priority: 0,
                       groupOrder: .originalPublisherOrder,
                       filterType: .latestGroup,
                       statusCallback: statusChanged)

        // Make task for cleaning up audio handlers.
        self.cleanupTask = .init(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let sleepTimer: TimeInterval
                if let self = self {
                    sleepTimer = self.cleanupTimer
                    self.handlerLock.withLock {
                        // Remove the audio handler if expired.
                        guard let lastUpdateTime = self.lastUpdateTime else { return }
                        if Date.now.timeIntervalSince(lastUpdateTime) >= self.cleanupTimer {
                            self.lastUpdateTime = nil
                            self.handler = nil
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
        self.lastUpdateTime = now

        // Metrics.
        let date: Date? = self.granularMetrics ? now : nil

        // TODO: Handle sequence rollover.
        if objectHeaders.groupId > self.seq {
            let missing = objectHeaders.groupId - self.seq - 1
            let currentSeq = self.seq
            if let measurement = measurement {
                Task(priority: .utility) {
                    await measurement.measurement.receivedBytes(received: UInt(data.count), timestamp: date)
                    if missing > 0 {
                        Self.logger.warning("LOSS! \(missing) packets. Had: \(currentSeq), got: \(objectHeaders.groupId)")
                        await measurement.measurement.missingSeq(missingCount: UInt64(missing), timestamp: date)
                    }
                }
            }
            self.seq = objectHeaders.groupId
        }

        // Do we need to create the handler?
        let handler: OpusHandler
        do {
            handler = try self.handlerLock.withLock {
                guard let handler = self.handler else {
                    let handler = try OpusHandler(identifier: self.profile.namespace.joined(),
                                                  engine: self.engine,
                                                  measurement: self.measurement,
                                                  jitterDepth: self.jitterDepth,
                                                  jitterMax: self.jitterMax,
                                                  opusWindowSize: self.opusWindowSize,
                                                  granularMetrics: self.granularMetrics,
                                                  useNewJitterBuffer: self.useNewJitterBuffer,
                                                  metricsSubmitter: self.metricsSubmitter)
                    self.handler = handler
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
                                           sequence: objectHeaders.groupId,
                                           date: now,
                                           timestamp: loc.timestamp)
        } catch {
            Self.logger.error("Failed to handle encoded audio: \(error.localizedDescription)")
        }
    }
}
