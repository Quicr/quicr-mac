import AVFAudio

/// Wrapper for app specific AVAudioEngine functionality.
class DecimusAudioEngine {

    /// The audio format the application should use.
    static let format: AVAudioFormat = .init(commonFormat: .pcmFormatFloat32,
                                             sampleRate: .opus48khz,
                                             channels: 1,
                                             interleaved: false)!

    private static let logger: DecimusLogger = .init(DecimusAudioEngine.self)

    /// The AVAudioEngine instance this AudioEngine wraps.
    let engine: AVAudioEngine = .init()

    private var blocks: MutableWrapper<[AnyHashable: AVAudioSinkNodeReceiverBlock]> = .init(value: [:])
    private var notificationObservers: [NSObjectProtocol] = []
    private let sink: AVAudioSinkNode
    private var stopped: Bool = false
    private var elements: [SourceIDType: AVAudioSourceNode] = [:]

    private lazy var reconfigure: (Notification) -> Void = { [weak self] _ in
        guard let self = self else { return }
        Self.logger.notice("AVAudioEngineConfigurationChange")
        do {
            try self.reconfigureAndRestart()
        } catch {
            Self.logger.critical("Failed to restart audio on config change. If you switched device, try again?")
        }
    }

    private lazy var interupt: (Notification) -> Void = { [weak self] notification in
        guard let self = self,
              let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // We got interupted.
            Self.logger.warning("Audio interuption")
        case .ended:
            // Resume.
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try self.reconfigureAndRestart()
                Self.logger.notice("Audio resumed")
            } catch {
                Self.logger.error("Failed to resume audio session")
            }
        @unknown default:
            Self.logger.warning("Got unexpected audio interuption value")
        }
    }

    private lazy var reset: (Notification) -> Void = { _ in
        Self.logger.warning("Media services reset. Report this.")
    }

    private lazy var routeChange: (Notification) -> Void = { notification in
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        Self.logger.notice("Route change: \(reason)")
    }

    init() throws {
        // Configure the session.
        let session = AVAudioSession.sharedInstance()
        try session.setSupportsMultichannelContent(false)
        try session.setCategory(.playAndRecord,
                                mode: .videoChat,
                                options: [.defaultToSpeaker, .allowBluetooth])

        // Enable voice processing.
        if !engine.outputNode.isVoiceProcessingEnabled {
            try engine.outputNode.setVoiceProcessingEnabled(true)
        }
        guard engine.outputNode.isVoiceProcessingEnabled,
              engine.inputNode.isVoiceProcessingEnabled else {
            throw "Voice processing missmatch"
        }

        // Ducking.
#if compiler(>=5.9)
        if #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, visionOS 1.0, *) {
            let ducking: AVAudioVoiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true,
                                                                                      duckingLevel: .min)
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = ducking
        }
#endif

        // Capture microphone audio.
        sink = .init { [weak blocks] timestamp, frames, data in
            guard let blocks = blocks else { return .zero }
            var success = true
            for block in blocks.value.values {
                success = success && block(timestamp, frames, data) == .zero
            }
            return success ? .zero : 1
        }
        engine.attach(sink)

        // Reconfigure first time.
        try localReconfigure()

        // Register interest in reconfigure events.
        let notifications: NotificationCenter = .default
        notificationObservers.append(notifications.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                               object: nil,
                                                               queue: nil,
                                                               using: reconfigure))
        notificationObservers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification,
                                                               object: AVAudioSession.sharedInstance(),
                                                               queue: nil,
                                                               using: interupt))
        notificationObservers.append(notifications.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                               object: AVAudioSession.sharedInstance(),
                                                               queue: nil,
                                                               using: reset))
        notificationObservers.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                               object: AVAudioSession.sharedInstance(),
                                                               queue: nil,
                                                               using: routeChange))
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Register a block that will be called with microphone data.
    /// You must register all blocks before calling start.
    /// - Parameter identifier: The identifier for this block.
    /// - Parameter block: The block to be called.
    func registerSinkBlock(identifier: AnyHashable, block: @escaping AVAudioSinkNodeReceiverBlock) throws {
        guard !engine.isRunning else { throw "Cannot alter blocks while running" }
        self.blocks.value[identifier] = block
    }

    /// Unregister a microphone sink block.
    /// - Parameter identifier: The identifier used to register this block.
    func unregisterSinkBlock(identifier: AnyHashable) throws {
        guard !engine.isRunning else { throw "Cannot alter blocks while running" }
        self.blocks.value.removeValue(forKey: identifier)
    }

    /// Run the audio engine.
    func start() throws {
        guard !engine.isRunning else { throw "Already running" }
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start()
        stopped = false
    }

    /// Stop the audio engine running.
    func stop() throws {
        guard engine.isRunning else { throw "Not running" }
        engine.stop()
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        stopped = true
    }

    /// Add a source node to this engine, to be mixed with any others.
    /// - Parameter identifier: Identifier for this source.
    /// - Parameter node: The source node supplying audio.
    func addPlayer(identifier: SourceIDType, node: AVAudioSourceNode) throws {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.format)
        assert(node.numberOfOutputs == 1)
        assert(node.outputFormat(forBus: 0) == Self.format)
        Self.logger.info("(\(identifier)) Attached node")
        guard self.elements[identifier] == nil else { throw "Add called for existing entry" }
        self.elements[identifier] = node
    }

    /// Remove a previously added source node.
    /// - Parameter identifier: Identifier of the source node to remove.
    func removePlayer(identifier: SourceIDType) throws {
        guard let element = elements.removeValue(forKey: identifier) else {
            throw "Remove called for non existent entry"
        }
        engine.detach(element)
        Self.logger.info("(\(identifier)) Removed player node")
    }

    private func localReconfigure() throws {
        // Reconfigure the audio session.
        let session: AVAudioSession = .sharedInstance()
        try session.setPreferredSampleRate(Self.format.sampleRate)

        // Inputs
        let preSetInput = session.inputNumberOfChannels
        try session.setPreferredInputNumberOfChannels(Int(Self.format.channelCount))
        let postSetInput = session.inputNumberOfChannels
        assert(preSetInput == postSetInput)

        // Outputs
        let preSetOutput = session.outputNumberOfChannels
        try session.setPreferredOutputNumberOfChannels(Int(Self.format.channelCount))
        let postSetOutput = session.outputNumberOfChannels
        assert(preSetOutput == postSetOutput)

        // We shouldn't be running at this point.
        assert(!engine.isRunning)

        // Sink for microphone output.
        engine.connect(engine.inputNode, to: sink, format: Self.format)
        assert(engine.inputNode.numberOfOutputs == 1)
        let inputOutputFormat = engine.inputNode.outputFormat(forBus: 0)
        Self.logger.info("Connected microphone: \(inputOutputFormat)")
        assert(inputOutputFormat == Self.format)
        assert(sink.numberOfInputs == 1)
        assert(sink.inputFormat(forBus: 0) == Self.format)

        // Mixer for player nodes.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: Self.format)
        assert(engine.mainMixerNode.numberOfOutputs == 1)
        let mixerOutputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        Self.logger.info("Connected mixer: \(mixerOutputFormat)")
        assert(mixerOutputFormat == Self.format)

        // Sanity check the output format.
        assert(engine.outputNode.numberOfInputs == 1)
        assert(engine.outputNode.isVoiceProcessingEnabled)
        assert(engine.outputNode.inputFormat(forBus: 0) == Self.format)

        // We shouldn't need to reconnect source nodes to the mixer,
        // as the format should not have changed.
        for element in self.elements {
            assert(element.value.numberOfOutputs == 1)
            let sourceOutputFormat = element.value.outputFormat(forBus: 0)
            assert(sourceOutputFormat == Self.format)
        }
    }

    private func reconfigureAndRestart() throws {
        guard !self.stopped else { return }
        if self.engine.isRunning {
            self.engine.stop()
        }

        // Reconfigure ourselves.
        try self.localReconfigure()

        // Restart.
        try self.start()
    }
}
