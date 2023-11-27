class VideoSubscription: QSubscriptionDelegateObjC {
    private static let logger = DecimusLogger(VideoSubscription.self)

    private let reliable: Bool
    private var videoHandlers: [QuicrNamespace: VideoHandler] = [:]

    init(sourceId: SourceIDType,
         profileSet: QClientProfileSet,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         namegate: NameGate,
         reliable: Bool,
         granularMetrics: Bool,
         jitterBufferConfig: VideoJitterBuffer.Config,
         hevcOverride: Bool) {
        self.reliable = reliable
        for profileIndex in 0..<profileSet.profilesCount {
            let profile = profileSet.profiles.advanced(by: profileIndex).pointee
            let config = CodecFactory.makeCodecConfig(from: .init(cString: profile.qualityProfile))
            guard let config = config as? VideoCodecConfig else {
                fatalError("Codec mismatch")
            }
            let adjustedConfig = hevcOverride ? .init(codec: .hevc, bitrate: config.bitrate, fps: config.fps, width: config.width, height: config.height) : config
            let namespace = QuicrNamespace(cString: profile.quicrNamespace)
            self.videoHandlers[namespace] = .init(namespace: namespace,
                                                  config: adjustedConfig,
                                                  participants: participants,
                                                  metricsSubmitter: metricsSubmitter,
                                                  namegate: namegate,
                                                  reliable: reliable,
                                                  granularMetrics: granularMetrics,
                                                  jitterBufferConfig: jitterBufferConfig)
        }
        Self.logger.info("Subscribed to video stream")
    }

    func prepare(_ sourceID: SourceIDType!,
                 label: String!,
                 profileSet: QClientProfileSet,
                 reliable: UnsafeMutablePointer<Bool>!) -> Int32 {
        reliable.pointee = self.reliable
        // self.video.labelName = label!
        // self.video.label = self.video.labelName
        return SubscriptionError.none.rawValue
    }

    func update(_ sourceId: String!, label: String!, profileSet: QClientProfileSet) -> Int32 {
        return SubscriptionError.noDecoder.rawValue
    }

    func subscribedObject(_ name: String!, data: UnsafeRawPointer!, length: Int, groupId: UInt32, objectId: UInt16) -> Int32 {
        let zeroCopiedData = Data(bytesNoCopy: .init(mutating: data), count: length, deallocator: .none)
        do {
            guard let handler = self.videoHandlers[name] else {
                throw "Unknown namespace"
            }
            try handler.submitEncodedData(zeroCopiedData, groupId: groupId, objectId: objectId)
        } catch {
            Self.logger.error("Failed to handle video data: \(error.localizedDescription)")
        }
        return SubscriptionError.none.rawValue
    }
}
