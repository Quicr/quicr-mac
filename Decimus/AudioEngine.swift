import AVFAudio
import Foundation

/// Application wrapper for AVAudioEngine instance.
class AudioEngine {
    private static let logger = DecimusLogger(AudioEngine.self)
    private static let opusSampleRates: [Double] = [.opus8khz, .opus12khz, .opus16khz, .opus24khz, .opus48khz]

    typealias ReconfigureEvent = () -> Void
    let engine: AVAudioEngine = .init()
    var blocks: MutableWrapper<[AVAudioSinkNodeReceiverBlock]> = .init(value: [])
    private(set) var desiredFormat: AVAudioFormat?
    private var observer: NSObjectProtocol?
    private var reconfigure: [AnyHashable: ReconfigureEvent] = [:]
    private let sink: AVAudioSinkNode

    init() throws {
        // Setup.
        try AVAudioSession.configureForDecimus()

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
        sink = .init { [blocks] timestamp, frames, data in
            var success = true
            for block in blocks.value {
                success = success && block(timestamp, frames, data) == .zero
            }
            return success ? .zero : 1
        }
        engine.attach(sink)

        // Configure input with desired format.
        localReconfigure()

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

    func start() throws {
        guard !engine.isRunning else { throw "Already running" }
        try engine.start()
    }

    func stop() throws {
        assert(engine.isRunning)
        engine.stop()
    }

    func registerReconfigureInterest(id: AnyHashable, callback: @escaping ReconfigureEvent) {
        reconfigure[id] = callback
    }

    func unregisterReconfigureInterest(id: AnyHashable) {
        reconfigure.removeValue(forKey: id)
    }

    private func localReconfigure() {
        // If voice processing is on, we want to override the format to something usable.
        let current = AVAudioSession.sharedInstance().sampleRate
        let desiredSampleRate = Self.opusSampleRates.contains(current) ? current : .opus48khz
        if engine.outputNode.isVoiceProcessingEnabled {
            desiredFormat = .init(commonFormat: engine.inputNode.outputFormat(forBus: 0).commonFormat,
                                  sampleRate: desiredSampleRate,
                                  channels: 1,
                                  interleaved: true)!
        } else {
            desiredFormat = nil
        }
        
        engine.connect(engine.inputNode, to: sink, format: desiredFormat)
    }

    private func reconfigure(notification: Notification) {

        Self.logger.info("AVAudioEngineConfigurationChange")

        // Reconfigure ourselves.
        localReconfigure()

        // Reconfigure everyone else.
        for listener in reconfigure {
            listener.value()
        }

        // Restart.
        do {
            try engine.start()
        } catch {
            fatalError(error.localizedDescription)
        }
    }
}
