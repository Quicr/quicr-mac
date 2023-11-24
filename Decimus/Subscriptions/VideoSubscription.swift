class VideoSubscription: QSubscriptionDelegateObjC {
    private static let logger = DecimusLogger(VideoSubscription.self)

    private let reliable: Bool
    private let video: VideoHandler

    init(namespace: QuicrNamespace,
         config: VideoCodecConfig,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         namegate: NameGate,
         reliable: Bool,
         granularMetrics: Bool,
         jitterBufferConfig: VideoJitterBuffer.Config,
         hevcOverride: Bool) {
        let adjustedConfig = hevcOverride ? .init(codec: .hevc, bitrate: config.bitrate, fps: config.fps, width: config.width, height: config.height) : config
        self.reliable = reliable
        self.video = .init(namespace: namespace,
                           config: adjustedConfig,
                           participants: participants,
                           metricsSubmitter: metricsSubmitter,
                           namegate: namegate,
                           reliable: reliable,
                           granularMetrics: granularMetrics,
                           jitterBufferConfig: jitterBufferConfig)

        Self.logger.info("Subscribed to video stream")
    }

    func prepare(_ sourceID: SourceIDType!,
                 label: String!,
                 qualityProfile: String!,
                 reliable: UnsafeMutablePointer<Bool>!) -> Int32 {
        reliable.pointee = self.reliable
        self.video.labelName = label!
        self.video.label = self.video.labelName
        return SubscriptionError.none.rawValue
    }

    func update(_ sourceId: String!, label: String!, qualityProfile: String!) -> Int32 {
        return SubscriptionError.noDecoder.rawValue
    }

    func subscribedObject(_ data: UnsafeRawPointer!, length: Int, groupId: UInt32, objectId: UInt16) -> Int32 {
        let zeroCopiedData = Data(bytesNoCopy: .init(mutating: data), count: length, deallocator: .none)
        do {
            try self.video.submitEncodedData(zeroCopiedData, groupId: groupId, objectId: objectId)
        } catch {
            Self.logger.error("Failed to handle video data: \(error.localizedDescription)")
        }
        return SubscriptionError.none.rawValue
    }
}
