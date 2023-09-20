import AVFAudio
import Foundation

/// Application wrapper for AVAudioEngine instance.
class AudioEngine {
    private static let logger = DecimusLogger(AudioEngine.self)
    private static let opusSampleRates: [Double] = [.opus8khz, .opus12khz, .opus16khz, .opus24khz, .opus48khz]

    /// Represents  an event signalling the audio engine has reconfigured.
    /// Downstream consumers should check the inputFormat, and reconfigure and reconnect any nodes as needed.
    typealias ReconfigureEvent = () -> Void
    
    /// The AVAudioEngine instance this AudioEngine wraps.
    let engine: AVAudioEngine = .init()

    private var blocks: MutableWrapper<[AVAudioSinkNodeReceiverBlock]> = .init(value: [])
    private(set) var inputFormat: AVAudioFormat
    private var lastInputFormat: AVAudioFormat
    private var observer: NSObjectProtocol?
    private var reconfigure: [AnyHashable: ReconfigureEvent] = [:]
    private let sink: AVAudioSinkNode

    /// Create a new AudioEngine, enable voice processing and prepare to capture microphone data.
    init() throws {
        // Setup.
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord,
                                     mode: .videoChat,
                                     options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true)

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
            Self.logger.info("Set voice processing ducking")
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = ducking
        }
#endif

        // Capture microphone audio.
        sink = .init { [blocks] timestamp, frames, data in
            var success = true
            for block in blocks.value {
                success = success && block(timestamp, frames, data) == .zero
            }
            return success ? .zero : 1
        }
        engine.attach(sink)

        // Configure input with desired format.
        self.inputFormat = Self.getUsableInputFormat(engine: engine)
        self.lastInputFormat = self.inputFormat
        engine.connect(engine.inputNode, to: sink, format: self.inputFormat)

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
    ///  - Parameter block: The block to be called.
    func registerSinkBlock(_ block: @escaping AVAudioSinkNodeReceiverBlock) {
        self.blocks.value.append(block)
    }

    /// Run the audio engine.
    func start() throws {
        guard !engine.isRunning else { throw "Already running" }
        try engine.start()
    }

    /// Stop the audio engine running.
    func stop() throws {
        guard engine.isRunning else { throw "Not running" }
        engine.stop()
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Register a handler that will be called when the audio engine reconfigures.
    /// Any connected blocks will need to be reconnected, and the format may have changed.
    /// - Parameter id: The identifier for this callback holder.
    /// - Parameter callback: Handler for the reconfigure event.
    func registerReconfigureInterest(id: AnyHashable, callback: @escaping ReconfigureEvent) {
        reconfigure[id] = callback
    }

    /// Unregister a previously registered reconfigure handler.
    /// - Parameter id: The identifier for the callback registration.
    func unregisterReconfigureInterest(id: AnyHashable) {
        reconfigure.removeValue(forKey: id)
    }

    private static func getUsableInputFormat(engine: AVAudioEngine) -> AVAudioFormat {
        // We want to override the format to something usable.
        let current = AVAudioSession.sharedInstance().sampleRate
        let desiredSampleRate: Double = .opus48khz
        assert(engine.inputNode.numberOfOutputs == 1)
        let inputOutputFormat = engine.inputNode.outputFormat(forBus: 0)
        assert(inputOutputFormat.sampleRate > 0)
        assert(inputOutputFormat.channelCount > 0)
        return .init(commonFormat: engine.inputNode.outputFormat(forBus: 0).commonFormat,
                     sampleRate: desiredSampleRate,
                     channels: 1,
                     interleaved: true)!
    }

    private func reconfigure(notification: Notification) {
        assert(!engine.isRunning)
        Self.logger.info("AVAudioEngineConfigurationChange")

        // Reconfigure ourselves.
        self.inputFormat = Self.getUsableInputFormat(engine: self.engine)
        if self.inputFormat != self.lastInputFormat {
            // Reconnect if we changed format.
            Self.logger.info("Reconnecting input node with format: \(self.inputFormat). Was: \(self.lastInputFormat)")
            engine.connect(engine.inputNode, to: sink, format: self.inputFormat)
        }
        self.lastInputFormat = self.inputFormat

        // Reconfigure everyone else.
        for listener in reconfigure {
            listener.value()
        }

        // Restart.
        do {
            try start()
        } catch {
            fatalError(error.localizedDescription)
        }
    }
}
