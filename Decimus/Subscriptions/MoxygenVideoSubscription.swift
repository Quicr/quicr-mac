// SPDX-FileCopyrightText: Copyright (c) 2024 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Configuration for creating moxygen video subscriptions.
struct MoxygenVideoSubscriptionConfig {
    let videoParticipants: VideoParticipants
    let metricsSubmitter: MetricsSubmitter?
    let subscriptionConfig: SubscriptionConfig
    let granularMetrics: Bool
    let joinDate: Date
    let activeSpeakerStats: ActiveSpeakerStats?
    let verbose: Bool
    let calculateLatency: Bool
    let mediaInterop: Bool
}

/// A video subscription that receives data via moxygen and feeds it to a VideoHandler.
class MoxygenVideoSubscription: NSObject, MoxygenTrackCallback {
    private static let logger = DecimusLogger(MoxygenVideoSubscription.self)

    private let handler: VideoHandler
    private let fullTrackName: FullTrackName
    private let profile: Profile
    private var objectCount: UInt64 = 0
    private let timeAligner: TimeAligner

    /// Create a moxygen video subscription.
    /// - Parameters:
    ///   - profile: The manifest profile for this subscription.
    ///   - config: Video codec configuration.
    ///   - factoryConfig: Factory configuration with shared dependencies.
    ///   - participantId: The participant ID for this subscription.
    ///   - variances: Variance calculator for jitter calculations.
    init(profile: Profile,
         config: VideoCodecConfig,
         factoryConfig: MoxygenVideoSubscriptionConfig,
         participantId: ParticipantId,
         variances: VarianceCalculator) throws {
        self.profile = profile
        self.fullTrackName = try profile.getFullTrackName()

        let subConfig = factoryConfig.subscriptionConfig
        let handlerConfig = VideoHandler.Config(
            calculateLatency: factoryConfig.calculateLatency,
            mediaInterop: factoryConfig.mediaInterop
        )

        self.handler = try VideoHandler(
            fullTrackName: fullTrackName,
            config: config,
            participants: factoryConfig.videoParticipants,
            metricsSubmitter: factoryConfig.metricsSubmitter,
            videoBehaviour: subConfig.videoBehaviour,
            reliable: subConfig.mediaReliability.video.subscription,
            granularMetrics: factoryConfig.granularMetrics,
            jitterBufferConfig: subConfig.videoJitterBuffer,
            simulreceive: subConfig.simulreceive,
            variances: variances,
            participantId: participantId,
            subscribeDate: Date.now,
            joinDate: factoryConfig.joinDate,
            activeSpeakerStats: factoryConfig.activeSpeakerStats,
            handlerConfig: handlerConfig,
            wifiDetector: nil
        )

        // Create a TimeAligner for this single handler.
        // Capture handler in a local variable to avoid capturing self before super.init().
        let capturedHandler = self.handler
        self.timeAligner = .init(windowLength: subConfig.videoJitterBuffer.window,
                                 capacity: Int(config.fps)) {
            [weak capturedHandler] in
            guard let handler = capturedHandler else { return [] }
            return [handler]
        }

        super.init()

        Self.logger.info("Created MoxygenVideoSubscription for \(fullTrackName)")
    }

    /// Start video playout.
    func play() {
        handler.play()
    }

    // MARK: - MoxygenTrackCallback

    func onObjectReceived(_ groupId: UInt64,
                          subgroupId: UInt64,
                          objectId: UInt64,
                          data: Data,
                          extensions: [NSNumber: [Data]]?,
                          immutableExtensions: [NSNumber: [Data]]?,
                          receiveTicks: UInt64) {
        objectCount += 1

        // Log periodically
        if objectCount % 30 == 1 {
            Self.logger.debug("[\(fullTrackName)] Received g=\(groupId) sg=\(subgroupId) o=\(objectId) size=\(data.count)")
        }

        // Construct QObjectHeaders from moxygen parameters
        var headers = QObjectHeaders()
        headers.groupId = groupId
        headers.objectId = objectId
        headers.payloadLength = UInt64(data.count)
        // priority and ttl are optional pointers, leave as nil

        // Forward to VideoHandler
        // For moxygen, we don't have the fetch/newgroup state machine,
        // so we pass drop=false and start playing on first keyframe
        let isKeyframe = objectId == 0

        handler.objectReceived(
            headers,
            data: data,
            extensions: immutableExtensions,
            when: receiveTicks,
            cached: false,
            drop: false
        )

        // Set time alignment from capture timestamp in extensions.
        // This enables proper jitter buffer timing calculations.
        if let immutableExtensions = immutableExtensions,
           let timestampData = try? immutableExtensions.getHeader(.captureTimestamp),
           case .captureTimestamp(let timestamp) = timestampData {
            timeAligner.doTimestampTimeDiff(timestamp.timeIntervalSince1970, when: receiveTicks)
        }

        // Start playout on first keyframe
        if isKeyframe && objectCount == 1 {
            Self.logger.info("[\(fullTrackName)] Starting playout on first keyframe")
            handler.play()
        }
    }

    func onSubscribeStatus(_ status: MoxygenSubscribeStatus, message: String?) {
        let statusStr: String
        switch status {
        case .ok: statusStr = "Ok"
        case .error: statusStr = "Error"
        case .done: statusStr = "Done"
        @unknown default: statusStr = "Unknown"
        }
        Self.logger.info("[\(fullTrackName)] Subscribe status: \(statusStr) \(message ?? "")")
    }
}

/// Factory for creating moxygen video subscriptions.
class MoxygenVideoSubscriptionFactory {
    private let config: MoxygenVideoSubscriptionConfig
    private let codecFactory: CodecFactory

    init(config: MoxygenVideoSubscriptionConfig, codecFactory: CodecFactory = CodecFactoryImpl()) {
        self.config = config
        self.codecFactory = codecFactory
    }

    /// Create a video subscription for the given profile.
    /// - Parameters:
    ///   - profile: The manifest profile.
    ///   - participantId: The participant ID.
    ///   - variances: Variance calculator (create one per subscription set).
    /// - Returns: A configured MoxygenVideoSubscription.
    func create(profile: Profile,
                participantId: ParticipantId,
                variances: VarianceCalculator) throws -> MoxygenVideoSubscription {
        let codecConfig = codecFactory.makeCodecConfig(
            from: profile.qualityProfile,
            bitrateType: config.subscriptionConfig.bitrateType
        )

        guard let videoConfig = codecConfig as? VideoCodecConfig else {
            throw "Profile \(profile.qualityProfile) is not a video codec"
        }

        return try MoxygenVideoSubscription(
            profile: profile,
            config: videoConfig,
            factoryConfig: config,
            participantId: participantId,
            variances: variances
        )
    }
}
