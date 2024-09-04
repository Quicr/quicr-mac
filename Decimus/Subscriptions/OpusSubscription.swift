import AVFAudio
import CoreAudio
import os

class OpusSubscription: QSubscribeTrackHandlerObjC, SubscriptionSet, QSubscribeTrackHandlerCallbacks {
    private static let logger = DecimusLogger(OpusSubscription.self)

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
    private let subscription: ManifestSubscription

    init(subscription: ManifestSubscription,
         engine: DecimusAudioEngine,
         submitter: MetricsSubmitter?,
         jitterDepth: TimeInterval,
         jitterMax: TimeInterval,
         opusWindowSize: OpusWindowSize,
         reliable: Bool,
         granularMetrics: Bool) throws {
        guard subscription.profileSet.profiles.count == 1,
              let profile = subscription.profileSet.profiles.first else {
            throw "OpusSubscription only supports one profile"
        }
        self.subscription = subscription
        self.engine = engine
        if let submitter = submitter {
            let measurement = OpusSubscriptionMeasurement(namespace: subscription.sourceID)
            self.measurement = .init(measurement: measurement, submitter: submitter)
        } else {
            self.measurement = nil
        }
        self.jitterDepth = jitterDepth
        self.jitterMax = jitterMax
        self.opusWindowSize = opusWindowSize
        self.reliable = reliable
        self.granularMetrics = granularMetrics

        // Create the actual audio handler upfront.
        self.handler = try .init(sourceId: self.subscription.sourceID,
                                 engine: self.engine,
                                 measurement: self.measurement,
                                 jitterDepth: self.jitterDepth,
                                 jitterMax: self.jitterMax,
                                 opusWindowSize: self.opusWindowSize,
                                 granularMetrics: self.granularMetrics)
        let fullTrackName = try FullTrackName(namespace: profile.namespace, name: "")
        super.init(fullTrackName: fullTrackName.getUnsafe())
        self.setCallbacks(self)

        // Make task for cleaning up audio handlers.
        self.cleanupTask = .init(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                self.handlerLock.withLock {
                    // Remove the audio handler if expired.
                    guard let lastUpdateTime = self.lastUpdateTime else { return }
                    if Date.now.timeIntervalSince(lastUpdateTime) >= self.cleanupTimer {
                        self.lastUpdateTime = nil
                        self.handler = nil
                    }
                }
                try? await Task.sleep(for: .seconds(self.cleanupTimer),
                                      tolerance: .seconds(self.cleanupTimer),
                                      clock: .continuous)
            }
        }

        Self.logger.info("Subscribed to OPUS stream")
    }

    func getHandlers() -> [QSubscribeTrackHandlerObjC] {
        return [self]
    }

    func statusChanged(_ status: QSubscribeTrackHandlerStatus) {
        Self.logger.info("Status changed: \(status)")
    }

    func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]) {
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
                    let handler = try OpusHandler(sourceId: self.subscription.sourceID,
                                                  engine: self.engine,
                                                  measurement: self.measurement,
                                                  jitterDepth: self.jitterDepth,
                                                  jitterMax: self.jitterMax,
                                                  opusWindowSize: self.opusWindowSize,
                                                  granularMetrics: self.granularMetrics)
                    self.handler = handler
                    return handler
                }
                return handler
            }
        } catch {
            Self.logger.error("Failed to recreate audio handler")
            return
        }

        do {
            try handler.submitEncodedAudio(data: data,
                                           sequence: objectHeaders.groupId,
                                           date: date)
        } catch {
            Self.logger.error("Failed to handle encoded audio: \(error.localizedDescription)")
        }
    }

    func partialObjectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]) {
        Self.logger.error("OpusSubscription unexpectedly received a partial object")
    }
}
