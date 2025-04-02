// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization
import AVFAudio

class PCMSubscription: Subscription {
    private static let logger = DecimusLogger(PCMSubscription.self)

    private let profile: Profile
    private let engine: DecimusAudioEngine
    // private let measurement: MeasurementRegistration<OpusSubscriptionMeasurement>?
    private let reliable: Bool
    private let granularMetrics: Bool
    private let handlers = Mutex<[UInt64: AudioHandler]>([:])
    private var cleanupTask: Task<(), Never>?
    private let cleanupTimer: TimeInterval
    private let lastUpdateTime = Mutex<[UInt64: Date?]>([:])
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
        var asbd = pcmFormat
        self.originalFormat = AVAudioFormat(streamDescription: &asbd)!

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
                    self.handlers.withLock { lockedHandlers in
                        self.lastUpdateTime.withLock { lockedUpdateTimes in
                            let now = Date.now
                            for time in lockedUpdateTimes {
                                guard let lastUpdateTime = time.value else { continue }
                                if now.timeIntervalSince(lastUpdateTime) >= self.cleanupTimer {
                                    lockedUpdateTimes[time.key] = nil
                                    lockedHandlers.removeValue(forKey: time.key)
                                }
                            }
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
        print("Received object \(objectHeaders.groupId):\(objectHeaders.objectId)")
        let now: Date = .now
        self.lastUpdateTime.withLock { $0[objectHeaders.groupId] = now }

        // Do we need to create the handler?
        let handler: AudioHandler
        do {
            handler = try self.handlers.withLock { lockedHandlers in
                guard let handler = lockedHandlers[objectHeaders.groupId] else {
                    let id = "\(self.fullTrackName.description):\(objectHeaders.groupId)"
                    let handler = try AudioHandler(identifier: id,
                                                   engine: self.engine,
                                                   decoder: PCMConverter(decodedFormat: DecimusAudioEngine.format,
                                                                         originalFormat: self.originalFormat,
                                                                         windowSize: self.opusWindowSize),
                                                   measurement: nil,
                                                   jitterDepth: self.jitterDepth,
                                                   jitterMax: self.jitterMax,
                                                   opusWindowSize: self.opusWindowSize,
                                                   granularMetrics: self.granularMetrics,
                                                   useNewJitterBuffer: self.useNewJitterBuffer,
                                                   metricsSubmitter: self.metricsSubmitter)
                    lockedHandlers[objectHeaders.groupId] = handler
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

        guard let chunk = try? ChunkMessage(from: data) else {
            Self.logger.warning("Failed to decode chunk message")
            return
        }

        do {
            try handler.submitEncodedAudio(data: chunk.data,
                                           sequence: objectHeaders.objectId,
                                           date: now,
                                           timestamp: loc.timestamp)
        } catch {
            Self.logger.error("Failed to handle encoded audio: \(error.localizedDescription)")
        }
    }
}
