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
    private let verbose: Bool

    var handler: VideoHandler?
    let handlerLock = OSAllocatedUnfairLock()

    private var cleanupTask: Task<(), Never>?
    private let cleanupTimer: TimeInterval
    private var lastUpdateTime = Date.now
    private let participantId: ParticipantId
    private let creationDate: Date
    private let joinDate: Date
    private let endpointId: String
    private let relayId: String

    // Fetch.
    private let controller: MoqCallController
    private var fetch: Fetch?
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
         verbose: Bool,
         cleanupTime: TimeInterval,
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
        self.verbose = verbose
        self.relayId = relayId
        self.endpointId = endpointId
        self.cleanupTimer = cleanupTime
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
                       filterType: .latestObject,
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
        if self.verbose {
            self.logger.debug("Received: \(objectHeaders.groupId) \(objectHeaders.objectId)")
        }

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
        var setPlay = false
        if !self.fetched {
            if objectHeaders.objectId == 0 {
                // We don't need a fetch.
                self.logger.debug("No fetch needed")
                self.fetched = true
                setPlay = true

                // Cancel existing, if any.
                if let fetch = self.fetch {
                    self.logger.debug("Cancelling in progress fetch")
                    do {
                        try self.controller.cancelFetch(fetch)
                    } catch {
                        self.logger.warning("Failed to cancel in progress fetch: \(error.localizedDescription)")
                    }
                    self.fetch = nil
                }
            } else if self.fetch == nil {
                do {
                    try self.fetch(currentGroup: objectHeaders.groupId,
                                   currentObject: objectHeaders.objectId)
                } catch {
                    self.logger.error("Failed to fetch: \(error.localizedDescription)")
                }
            }
        }

        // Handle this object.
        handler.objectReceived(objectHeaders, data: data, extensions: extensions, when: now, cached: false)
        if setPlay {
            handler.play()
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

    private func fetch(currentGroup: UInt64, currentObject: UInt64) throws {
        // TODO: What should the priority be?
        self.logger.debug("Starting fetch for \(currentGroup):0->\(currentObject)")
        let fetch = CallbackFetch(ftn: self.fullTrackName,
                                  priority: 0,
                                  groupOrder: .originalPublisherOrder,
                                  startGroup: currentGroup,
                                  endGroup: currentGroup + 1,
                                  startObject: 0,
                                  endObject: currentObject,
                                  verbose: self.verbose,
                                  metricsSubmitter: self.metricsSubmitter,
                                  endpointId: self.endpointId,
                                  relayId: self.relayId,
                                  statusChanged: { [weak self] status in
                                    guard let self = self else { return }
                                    let message = "Fetch status changed: \(status)"
                                    if status.isError && !self.fetched && status == .notConnected {
                                        self.logger.error(message)
                                    } else {
                                        self.logger.info(message)
                                    }
                                  },
                                  objectReceived: {[weak self] headers, data, extensions in
                                    guard let self = self else { return }
                                    self.onFetchedObject(headers: headers,
                                                         data: data,
                                                         extensions: extensions,
                                                         currentGroup: currentGroup,
                                                         currentObject: currentObject)
                                  })
        self.fetch = fetch
        try controller.fetch(fetch)
    }

    private func onFetchedObject(headers: QObjectHeaders,
                                 data: Data,
                                 extensions: [NSNumber: Data]?,
                                 currentGroup: UInt64,
                                 currentObject: UInt64) {
        // Got an object from fetch.
        if self.verbose {
            self.logger.debug("Fetched: \(headers.groupId):\(headers.objectId)")
        }
        guard let handler = self.handler else { return }
        handler.objectReceived(headers, data: data, extensions: extensions, when: .now, cached: true)

        // Are we done?
        if headers.groupId == currentGroup,
           headers.objectId == currentObject - 1 {
            self.logger.info("Video Fetch complete")
            self.fetched = true
            handler.play()
            guard let fetch = self.fetch else { return }
            try? self.controller.cancelFetch(fetch)
        }
    }
}
