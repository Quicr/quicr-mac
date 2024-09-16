// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import os

/// Represents a QuicR video subscription.
/// Holds an object for decoding & rendering.
/// Manages lifetime of said renderer.
/// Forwards data from callbacks.
class VideoSubscription: QSubscribeTrackHandlerObjC, QSubscribeTrackHandlerCallbacks {
    private let fullTrackName: FullTrackName
    private let config: VideoCodecConfig
    private let participants: VideoParticipants
    private let metricsSubmitter: MetricsSubmitter?
    private let videoBehaviour: VideoBehaviour
    private let reliable: Bool
    private let granularMetrics: Bool
    private let jitterBufferConfig: VideoJitterBuffer.Config
    private let simulreceive: SimulreceiveMode
    private let variances: VarianceCalculator
    private let callback: ObjectReceived
    private var token: Int = 0
    private let logger = DecimusLogger(VideoSubscription.self)
    private let measurement: MeasurementRegistration<TrackMeasurement>?

    var handler: VideoHandler?
    let handlerLock = OSAllocatedUnfairLock()

    private var cleanupTask: Task<(), Never>?
    private let cleanupTimer: TimeInterval = 1.5
    private var lastUpdateTime = Date.now

    init(fullTrackName: FullTrackName,
         config: VideoCodecConfig,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         videoBehaviour: VideoBehaviour,
         reliable: Bool,
         granularMetrics: Bool,
         jitterBufferConfig: VideoJitterBuffer.Config,
         simulreceive: SimulreceiveMode,
         variances: VarianceCalculator,
         endpointId: String,
         relayId: String,
         callback: @escaping ObjectReceived) throws {
        self.fullTrackName = fullTrackName
        self.config = config
        self.participants = participants
        self.metricsSubmitter = metricsSubmitter
        self.videoBehaviour = videoBehaviour
        self.reliable = reliable
        self.granularMetrics = granularMetrics
        self.jitterBufferConfig = jitterBufferConfig
        self.simulreceive = simulreceive
        self.variances = variances
        self.callback = callback

        if let metricsSubmitter = metricsSubmitter {
            let measurement = TrackMeasurement(type: .subscribe,
                                               endpointId: endpointId,
                                               relayId: relayId,
                                               namespace: try fullTrackName.getNamespace())
            self.measurement = .init(measurement: measurement, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }

        let handler = try VideoHandler(fullTrackName: fullTrackName,
                                       config: config,
                                       participants: participants,
                                       metricsSubmitter: metricsSubmitter,
                                       videoBehaviour: videoBehaviour,
                                       reliable: reliable,
                                       granularMetrics: granularMetrics,
                                       jitterBufferConfig: jitterBufferConfig,
                                       simulreceive: simulreceive,
                                       variances: variances)
        self.token = handler.registerCallback(callback)
        self.handler = handler

        super.init(fullTrackName: fullTrackName.getUnsafe())
        self.setCallbacks(self)
    }

    deinit {
        self.logger.debug("Deinit")
    }

    func statusChanged(_ status: QSubscribeTrackHandlerStatus) {
        self.logger.info("Subscribe Track Status Changed: \(status)")
    }

    func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        if self.cleanupTask == nil {
            self.cleanupTask = .init(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    let duration: TimeInterval
                    if let self = self {
                        duration = self.cleanupTimer
                        if Date.now.timeIntervalSince(self.lastUpdateTime) >= self.cleanupTimer {
                            self.handlerLock.withLock {
                                self.handler?.unregisterCallback(self.token)
                                self.token = 0
                                self.handler = nil
                            }
                        }
                    } else {
                        return
                    }
                    try? await Task.sleep(for: .seconds(duration))
                }
            }
        }

        let now = Date.now
        self.lastUpdateTime = now

        let handler: VideoHandler
        do {
            handler = try self.getCreateHandler()
        } catch {
            self.logger.error("Failed to recreate video handler: \(error.localizedDescription)")
            return
        }

        handler.objectReceived(objectHeaders, data: data, extensions: extensions, when: now)
    }

    func partialObjectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        self.logger.warning("Partial objects not supported")
    }

    func metricsSampled(_ metrics: UnsafePointer<QSubscribeTrackMetrics>) {
        if let measurement = self.measurement?.measurement {
            let copy = metrics.pointee
            Task(priority: .utility) {
                await measurement.record(copy)
            }
        }
    }

    private func getCreateHandler() throws -> VideoHandler {
        self.handlerLock.lock()
        let handler: VideoHandler
        if let unwrapped = self.handler {
            handler = unwrapped
        } else {
            let recreated = try VideoHandler(fullTrackName: self.fullTrackName,
                                             config: self.config,
                                             participants: self.participants,
                                             metricsSubmitter: self.metricsSubmitter,
                                             videoBehaviour: self.videoBehaviour,
                                             reliable: self.reliable,
                                             granularMetrics: self.granularMetrics,
                                             jitterBufferConfig: self.jitterBufferConfig,
                                             simulreceive: self.simulreceive,
                                             variances: self.variances)
            self.token = recreated.registerCallback(self.callback)
            self.handler = recreated
            handler = recreated
        }
        self.handlerLock.unlock()
        return handler
    }
}
