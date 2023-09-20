import AVFAudio

/// Wrapper for app specific AVAudioEngine functionality.
class DecimusAudioEngine {

    /// The audio format the application should use.
    static let format: AVAudioFormat = .init(commonFormat: .pcmFormatFloat32,
                                             sampleRate: .opus48khz,
                                             channels: 1,
                                             interleaved: true)!

    private static let logger: DecimusLogger = .init(DecimusAudioEngine.self)

    /// Represents  an event signalling the audio engine has reconfigured.
    /// Downstream consumers should check the inputFormat, and reconfigure and reconnect any nodes as needed.
    typealias ReconfigureEvent = () -> Void
    
    /// The AVAudioEngine instance this AudioEngine wraps.
    let engine: AVAudioEngine = .init()

    private var blocks: MutableWrapper<[AnyHashable: AVAudioSinkNodeReceiverBlock]> = .init(value: [:])
    private var observer: NSObjectProtocol?
    private var reconfigureListeners: [AnyHashable: ReconfigureEvent] = [:]
    private let sink: AVAudioSinkNode
    private var stopped: Bool = false

    private lazy var reconfigure: (Notification) -> Void = { [weak self] _ in
        guard let self = self else { return }
        guard !self.stopped else { return }

        Self.logger.log(level: .info, "AVAudioEngineConfigurationChange", alert: true)
        if self.engine.isRunning {
            self.engine.stop()
        }

        do {
            // Reconfigure ourselves.
            try self.localReconfigure()

            // Reconfigure everyone else.
            for listener in self.reconfigureListeners {
                listener.value()
            }

            // Restart if appropriate.
            try self.start()
        } catch {
            Self.logger.critical("Failed to restart audio on config change. If you switched device, try again?")
        }
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
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: nil,
                                                          queue: nil,
                                                          using: reconfigure)
    }

    deinit {
        if let observer = observer {
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

    /// Register a handler that will be called when the audio engine reconfigures.
    /// Any connected blocks will need to be reconnected, and the format may have changed.
    /// - Parameter id: The identifier for this callback holder.
    /// - Parameter callback: Handler for the reconfigure event.
    func registerReconfigureInterest(id: AnyHashable, callback: @escaping ReconfigureEvent) {
        reconfigureListeners[id] = callback
    }

    /// Unregister a previously registered reconfigure handler.
    /// - Parameter id: The identifier for the callback registration.
    func unregisterReconfigureInterest(id: AnyHashable) {
        reconfigureListeners.removeValue(forKey: id)
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

        // Reconfigure ourselves.
        assert(!engine.isRunning)
        engine.connect(engine.inputNode, to: sink, format: Self.format)
        assert(engine.inputNode.numberOfOutputs == 1)
        let inputOutputFormat = engine.inputNode.outputFormat(forBus: 0)
        Self.logger.info("Connected microphone: \(inputOutputFormat)")
        assert(inputOutputFormat == Self.format)
        assert(sink.numberOfInputs == 1)
        assert(sink.inputFormat(forBus: 0) == Self.format)
    }
}
