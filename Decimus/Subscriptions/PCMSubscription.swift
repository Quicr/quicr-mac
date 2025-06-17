// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization
import AVFAudio

protocol AudioSubscription: Subscription {
    func startListening()
    func stopListening()
}

class PCMSubscription: Subscription, AudioSubscription {
    private let logger: DecimusLogger

    private let profile: Profile
    private let engine: DecimusAudioEngine
    private let measurement: MeasurementRegistration<OpusSubscription.OpusSubscriptionMeasurement>?
    private let reliable: Bool
    private let handlers = Mutex<[UInt64: AudioHandler]>([:])
    private var cleanupTask: Task<(), Never>?
    private let cleanupTimer: TimeInterval
    private let lastUpdateTime = Mutex<[UInt64: Date?]>([:])
    private let metricsSubmitter: MetricsSubmitter?
    private let fullTrackName: FullTrackName
    private let originalFormat: AVAudioFormat
    private let verbose: Bool
    private let ourGroupId: UInt64?
    private let listen: Atomic<Bool> = .init(true)
    private let sframeContext: SFrameContext?
    private let config: AudioHandler.Config

    init(profile: Profile,
         engine: DecimusAudioEngine,
         submitter: MetricsSubmitter?,
         reliable: Bool,
         config: AudioHandler.Config,
         endpointId: String,
         relayId: String,
         cleanupTime: TimeInterval,
         verbose: Bool,
         ourGroupId: UInt64?,
         sframeContext: SFrameContext?,
         statusChanged: @escaping StatusCallback) throws {
        self.profile = profile
        self.engine = engine
        self.metricsSubmitter = submitter
        self.config = config
        self.reliable = reliable
        self.cleanupTimer = cleanupTime
        self.verbose = verbose
        self.ourGroupId = ourGroupId
        self.sframeContext = sframeContext

        // Original PCM format.
        var asbd = pcmFormat
        self.originalFormat = AVAudioFormat(streamDescription: &asbd)!

        let fullTrackName = try profile.getFullTrackName()
        self.fullTrackName = fullTrackName
        self.logger = DecimusLogger(PCMSubscription.self, prefix: self.fullTrackName.description)
        if let submitter {
            self.measurement = .init(measurement: .init(namespace: profile.namespace.joined()), submitter: submitter)
        } else {
            self.measurement = nil
        }
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

        self.logger.info("Subscribed to PCM stream")
    }

    deinit {
        self.logger.debug("Deinit")
    }

    func startListening() {
        self.listen.store(true, ordering: .releasing)
    }

    func stopListening() {
        self.listen.store(false, ordering: .releasing)
    }

    override func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        let unprotected: Data
        if let sframeContext {
            do {
                unprotected = try sframeContext.mutex.withLock { try $0.unprotect(ciphertext: data) }
            } catch {
                self.logger.error("Failed to unprotect data: \(error.localizedDescription)")
                return
            }
        } else {
            unprotected = data
        }

        let listen = self.listen.load(ordering: .acquiring)
        if let startingGroupId = self.ourGroupId,
           objectHeaders.groupId == startingGroupId {
            // Dont listen to ourself.
            if self.verbose {
                self.logger.debug("Recv own audio: \(objectHeaders.groupId):\(objectHeaders.objectId). Listening: \(listen)")
            }
            return
        }

        if self.verbose {
            self.logger.debug("Recv audio: \(objectHeaders.groupId):\(objectHeaders.objectId). Listening: \(listen)")
        }

        guard listen else { return }

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
                                                                         windowSize: self.config.opusWindowSize),
                                                   measurement: nil,
                                                   metricsSubmitter: self.metricsSubmitter,
                                                   config: self.config)
                    lockedHandlers[objectHeaders.groupId] = handler
                    return handler
                }
                return handler
            }
        } catch {
            self.logger.error("Failed to recreate audio handler")
            return
        }

        let loc: LowOverheadContainer
        if let extensions,
           let parsed = try? LowOverheadContainer(from: extensions) {
            loc = parsed
        } else {
            self.logger.warning("Missing expected LOC headers")
            loc = .init(timestamp: now, sequence: nil)
        }

        if self.config.granularMetrics,
           let measurement = self.measurement?.measurement {
            Task(priority: .utility) {
                await measurement.arrived(timestamp: loc.timestamp, metricsTimestamp: now)

            }
        }

        guard let chunk = try? AudioChunk(from: unprotected) else {
            self.logger.warning("Failed to decode audio chunk")
            return
        }

        do {
            try handler.submitEncodedAudio(data: chunk.audioData,
                                           sequence: objectHeaders.objectId,
                                           date: now,
                                           timestamp: loc.timestamp)
        } catch {
            self.logger.error("Failed to handle encoded audio: \(error.localizedDescription)")
        }
    }
}
