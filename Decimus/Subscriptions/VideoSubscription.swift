// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import os

/// Represents a QuicR video subscription.
/// Holds an object for decoding & rendering.
/// Manages lifetime of said renderer.
/// Forwards data from callbacks.
class VideoSubscription: Subscription {
    typealias StatusChanged = (_ status: QSubscribeTrackHandlerStatus) -> Void
    private let fullTrackName: FullTrackName
    private let config: VideoCodecConfig
    private let participants: VideoParticipants
    private let metricsSubmitter: MetricsSubmitter?
    private let videoBehaviour: VideoBehaviour
    private let reliable: Bool
    private let granularMetrics: Bool
    private let jitterBufferConfig: JitterBuffer.Config
    private let simulreceive: SimulreceiveMode
    private let variances: VarianceCalculator
    private let callback: ObjectReceived
    private var token: Int = 0
    private let logger = DecimusLogger(VideoSubscription.self)

    var handler: VideoHandler?
    let handlerLock = OSAllocatedUnfairLock()

    private var cleanupTask: Task<(), Never>?
    private let cleanupTimer: TimeInterval = 1.5
    private var lastUpdateTime = Date.now
    private let participantId: ParticipantId
    private let creationDate: Date
    private let joinDate: Date

    // Fetch.
    private let controller: MoqCallController
    private var fetch: CallbackFetch?
    private var fetched = false

    init(profile: Profile,
         config: VideoCodecConfig,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         videoBehaviour: VideoBehaviour,
         reliable: Bool,
         granularMetrics: Bool,
         jitterBufferConfig: JitterBuffer.Config,
         simulreceive: SimulreceiveMode,
         variances: VarianceCalculator,
         endpointId: String,
         relayId: String,
         participantId: ParticipantId,
         joinDate: Date,
         controller: MoqCallController,
         callback: @escaping ObjectReceived,
         statusChanged: @escaping StatusChanged) throws {
        self.fullTrackName = try profile.getFullTrackName()
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
        self.participantId = participantId
        self.creationDate = .now
        self.joinDate = joinDate
        self.controller = controller
        let handler = try VideoHandler(fullTrackName: fullTrackName,
                                       config: config,
                                       participants: participants,
                                       metricsSubmitter: metricsSubmitter,
                                       videoBehaviour: videoBehaviour,
                                       reliable: reliable,
                                       granularMetrics: granularMetrics,
                                       jitterBufferConfig: jitterBufferConfig,
                                       simulreceive: simulreceive,
                                       variances: variances,
                                       participantId: participantId,
                                       subscribeDate: self.creationDate,
                                       joinDate: joinDate)
        self.token = handler.registerCallback(callback)
        self.handler = handler
        try super.init(profile: profile,
                       endpointId: endpointId,
                       relayId: relayId,
                       metricsSubmitter: metricsSubmitter,
                       priority: 0,
                       groupOrder: .originalPublisherOrder,
                       filterType: .latestGroup,
                       statusCallback: statusChanged)
    }

    deinit {
        self.logger.debug("Deinit")
    }

    private func cleanup() {
        self.handlerLock.withLock {
            guard let handler = self.handler else { return }
            self.handler = nil
            handler.unregisterCallback(self.token)
            self.token = 0
        }
    }

    override func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        if self.cleanupTask == nil {
            self.cleanupTask = .init(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    let duration: TimeInterval
                    if let self = self {
                        duration = self.cleanupTimer
                        if Date.now.timeIntervalSince(self.lastUpdateTime) >= self.cleanupTimer {
                            self.cleanup()
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

        // Do we need to start a fetch?
        if objectHeaders.objectId == 0 {
            // We don't need a fetch, or the in progress fetch can go.
            self.logger.debug("No fetch needed")
            self.fetched = true
            if let fetch = self.fetch {
                self.logger.debug("Cancelling in progress fetch")
                do {
                    try self.controller.cancelFetch(fetch)
                } catch {
                    self.logger.warning("Failed to cancel in progress fetch: \(error.localizedDescription)")
                }
                self.fetch = nil
            }
        } else if !self.fetched && self.fetch == nil {
            self.logger.debug("Starting fetch, given I got obj:\(objectHeaders.objectId)")
            let fetch = CallbackFetch(ftn: self.fullTrackName,
                                      priority: 0,
                                      groupOrder: .originalPublisherOrder,
                                      startGroup: objectHeaders.groupId,
                                      endGroup: objectHeaders.groupId,
                                      startObject: 0,
                                      endObject: objectHeaders.objectId,
                                      statusChanged: ({_ in}),
                                      objectReceived: ({[weak handler, weak self] headers, data, extensions in
                                        guard let handler = handler,
                                              let self = self else { return }
                                        self.logger.debug("Fetch got: \(headers.objectId)")
                                        handler.objectReceived(headers, data: data, extensions: extensions, when: .now)

                                        // Are we done?
                                        if headers.groupId == objectHeaders.groupId,
                                           headers.objectId == objectHeaders.objectId - 1 {
                                            self.logger.info("Video Fetch complete")
                                            self.fetched = true
                                            self.fetch = nil
                                            // TODO: Cancel.
                                        }
                                      }))
            do {
                try controller.fetch(fetch)
            } catch {
                self.logger.error("Failed to start fetch operation: \(error.localizedDescription)")
            }
            self.fetch = fetch
        }

        // Handle this object.
        handler.objectReceived(objectHeaders, data: data, extensions: extensions, when: now)
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
                                             participantId: self.participantId,
                                             subscribeDate: self.creationDate,
                                             joinDate: self.joinDate)
            self.token = recreated.registerCallback(self.callback)
            self.handler = recreated
            handler = recreated
        }
        self.handlerLock.unlock()
        return handler
    }
}
