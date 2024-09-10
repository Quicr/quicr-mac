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
    private let userData: UnsafeRawPointer
    private let logger = DecimusLogger(VideoSubscription.self)

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
         callback: @escaping ObjectReceived,
         userData: UnsafeRawPointer) throws {
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
        self.userData = userData

        self.handler = try .init(fullTrackName: fullTrackName,
                                 config: config,
                                 participants: participants,
                                 metricsSubmitter: metricsSubmitter,
                                 videoBehaviour: videoBehaviour,
                                 reliable: reliable,
                                 granularMetrics: granularMetrics,
                                 jitterBufferConfig: jitterBufferConfig,
                                 simulreceive: simulreceive,
                                 variances: variances,
                                 callback: callback,
                                 userData: userData)

        super.init(fullTrackName: fullTrackName.getUnsafe())
        self.setCallbacks(self)

        self.cleanupTask = .init(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                if Date.now.timeIntervalSince(self.lastUpdateTime) >= self.cleanupTimer {
                    self.handlerLock.withLock {
                        self.handler = nil
                    }
                }
                try? await Task.sleep(for: .seconds(self.cleanupTimer))
            }
        }
    }

    func statusChanged(_ status: QSubscribeTrackHandlerStatus) {
        self.logger.info("Subscribe Track Status Changed: \(status)")
    }

    func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
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
                                             variances: self.variances,
                                             callback: self.callback,
                                             userData: self.userData)
            self.handler = recreated
            handler = recreated
        }
        self.handlerLock.unlock()
        return handler
    }
}
