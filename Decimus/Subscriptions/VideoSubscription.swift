import AVFoundation

enum SimulreceiveMode: Codable, CaseIterable, Identifiable {
    case none
    case visualizeOnly
    case enable
    var id: Self { self }
}

class VideoSubscription: QSubscriptionDelegateObjC {
    private static let logger = DecimusLogger(VideoSubscription.self)

    private let sourceId: SourceIDType
    private let participants: VideoParticipants
    private let reliable: Bool
    private var videoHandlers: [QuicrNamespace: VideoHandler] = [:]
    private var renderTask: Task<(), Never>?
    private let simulreceive: SimulreceiveMode
    private var lastTime: CMTime?
    private var qualityMisses = 0
    private var lastQuality: Int32?
    private let qualityMissThreshold: Int
    private var lastVideoHandler: VideoHandler?

    init(sourceId: SourceIDType,
         profileSet: QClientProfileSet,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         namegate: NameGate,
         reliable: Bool,
         granularMetrics: Bool,
         jitterBufferConfig: VideoJitterBuffer.Config,
         hevcOverride: Bool,
         simulreceive: SimulreceiveMode,
         qualityMissThreshold: Int) throws {
        if simulreceive != .none && jitterBufferConfig.mode == .layer {
            throw "Simulreceive and layer are not compatible"
        }

        self.sourceId = sourceId
        self.participants = participants
        self.reliable = reliable
        self.simulreceive = simulreceive
        self.qualityMissThreshold = qualityMissThreshold
        for profileIndex in 0..<profileSet.profilesCount {
            let profile = profileSet.profiles.advanced(by: profileIndex).pointee
            let config = CodecFactory.makeCodecConfig(from: .init(cString: profile.qualityProfile))
            guard let config = config as? VideoCodecConfig else {
                throw "Codec mismatch"
            }
            let adjustedConfig = hevcOverride ? .init(codec: .hevc,
                                                      bitrate: config.bitrate,
                                                      fps: config.fps,
                                                      width: config.width,
                                                      height: config.height) : config
            let namespace = QuicrNamespace(cString: profile.quicrNamespace)
            self.videoHandlers[namespace] = try .init(namespace: namespace,
                                                      config: adjustedConfig,
                                                      participants: participants,
                                                      metricsSubmitter: metricsSubmitter,
                                                      namegate: namegate,
                                                      reliable: reliable,
                                                      granularMetrics: granularMetrics,
                                                      jitterBufferConfig: jitterBufferConfig,
                                                      simulreceive: self.simulreceive)
        }

        // Make task to do simulreceive.
        if self.simulreceive != .none {
            self.renderTask = .init(priority: .high) { [weak self] in
                while !Task.isCancelled {
                    guard let self = self else { return }
                    await self.makeSimulreceiveDecision()
                }
            }
        }

        Self.logger.info("Subscribed to video stream")
    }

    deinit {
        if self.simulreceive != .none {
            do {
                try self.participants.removeParticipant(identifier: self.sourceId)
            } catch {
                Self.logger.error("Failed to remove participant")
            }
        }
    }

    func prepare(_ sourceID: SourceIDType!,
                 label: String!,
                 profileSet: QClientProfileSet,
                 reliable: UnsafeMutablePointer<Bool>!) -> Int32 {
        reliable.pointee = self.reliable
        return SubscriptionError.none.rawValue
    }

    func update(_ sourceId: String!, label: String!, profileSet: QClientProfileSet) -> Int32 {
        return SubscriptionError.noDecoder.rawValue
    }

    func subscribedObject(_ name: String!, data: UnsafeRawPointer!, length: Int, groupId: UInt32, objectId: UInt16) -> Int32 {
        // Update keep alive timer for showing video.
        if self.simulreceive == .enable {
            DispatchQueue.main.async {
                let participant = self.participants.getOrMake(identifier: self.sourceId)
                participant.lastUpdated = .now()
            }
        }

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

    private func makeSimulreceiveDecision() async {
        // Get available decoded frames from all handlers.
        var retrievedFrames: [VideoHandler: CMSampleBuffer] = [:]
        var highestFps: UInt16?
        for handler in self.videoHandlers.values {
            // Is a frame available?
            if highestFps == nil || handler.config.fps > highestFps! {
                highestFps = handler.config.fps
            }

            if let frame = handler.getLastImage() {
                retrievedFrames[handler] = frame
            }
        }

        // No decision to make.
        guard retrievedFrames.count > 0 else {
            let duration: TimeInterval
            if let lastHandler = self.lastVideoHandler {
                duration = lastHandler.calculateWaitTime()
            } else {
                duration = 1 / TimeInterval(highestFps!)
            }
            try? await Task.sleep(for: .seconds(duration))
            return
        }

        // Oldest should be the oldest value that hasn't already been shown.
        var oldest: CMTime?
        for (handler, frame) in retrievedFrames {
            if let lastTime = self.lastTime,
               frame.presentationTimeStamp < lastTime {
                // This would be backwards in time, so we'll never use it.
                handler.removeLastImage(sample: frame)
                continue
            }

            // Take the oldest frame.
            if oldest == nil || frame.presentationTimeStamp < oldest! {
                oldest = frame.presentationTimeStamp
            }
        }

        // Filter out any frames that don't match the desired point in time.
        retrievedFrames = retrievedFrames.filter {
            $0.value.presentationTimeStamp == oldest
        }

        // Now we've decided our point in time,
        // pop off the ones for the time we're using so we don't get them next time.
        for pair in retrievedFrames {
            pair.key.removeLastImage(sample: pair.value)
        }

        // We'll use the highest quality frame of the selected ones.
        let sorted = retrievedFrames.sorted {
            $0.0.config.width > $1.0.config.width
        }

        guard let first = sorted.first else { fatalError() }

        let sample = first.value
        let width = sample.formatDescription!.dimensions.width
        if let lastQuality = self.lastQuality,
           width < lastQuality {
            self.qualityMisses += 1
        }

        // We only want to step down in quality if we've missed a few hits.
        if let lastQuality = self.lastQuality,
           width < lastQuality && self.qualityMisses < self.qualityMissThreshold {
            await calculateWaitTime(videoHandler: first.key)
            return
        }

        // Proceed with rendering this frame.
        self.qualityMisses = 0
        self.lastQuality = sample.formatDescription!.dimensions.width

        if self.simulreceive == .enable {
            // Set to display immediately.
            if sample.sampleAttachments.count > 0 {
                sample.sampleAttachments[0][.displayImmediately] = true
            } else {
                Self.logger.warning("Couldn't set display immediately attachment")
            }

            // Enqueue the sample on the main thread.
            DispatchQueue.main.async {
                let participant = self.participants.getOrMake(identifier: self.sourceId)
                participant.view.label = first.key.label
                do {
                    try participant.view.enqueue(sample, transform: CATransform3DIdentity)
                } catch {
                    Self.logger.error("Could not enqueue sample: \(error)")
                }
                participant.lastUpdated = .now()
            }
        } else if self.simulreceive == .visualizeOnly {
            DispatchQueue.main.async {
                for participant in self.participants.participants {
                    participant.value.view.highlight = participant.key == first.key.namespace
                }
            }
        }

        // Wait until we have expect to have the next frame available.
        await calculateWaitTime(videoHandler: first.key)
    }

    private func calculateWaitTime(videoHandler: VideoHandler?) async {
        // Wait until we have expect to have the next frame available.
        guard let videoHandler = videoHandler else { return }
        let waitTime: TimeInterval = videoHandler.calculateWaitTime()
        if waitTime > 0 {
            try? await Task.sleep(for: .seconds(waitTime),
                                  tolerance: .seconds(waitTime / 2),
                                  clock: .continuous)
        }
    }
}
