import AVFoundation
import CoreAudio
import CTPCircularBuffer
import os

/// Plays audio samples out.
class FasterAVEngineAudioPlayer: Hashable {

    static func == (lhs: FasterAVEngineAudioPlayer, rhs: FasterAVEngineAudioPlayer) -> Bool {
        lhs.engine.engine == rhs.engine.engine
    }

    private static let logger = DecimusLogger(FasterAVEngineAudioPlayer.self)

    private(set) var inputFormat: AVAudioFormat?
    private unowned let engine: AudioEngine
    private var mixer: AVAudioMixerNode = .init()
    private var elements: [SourceIDType: AVAudioSourceNode] = [:]

    /// Create a new `AudioPlayer`
    init(engine: AudioEngine) {
        assert(engine.engine.outputNode.isVoiceProcessingEnabled)
        assert(engine.engine.outputNode.numberOfInputs == 1)
        self.engine = engine
        reconnect()
        self.engine.registerReconfigureInterest(id: self, callback: reconnect)
    }

    deinit {
        for identifier in elements.keys {
            removePlayer(identifier: identifier)
        }
        elements.removeAll()

        let engine = engine.engine
        engine.disconnectNodeInput(mixer)
        engine.detach(mixer)
        self.engine.unregisterReconfigureInterest(id: self)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(engine.engine)
    }

    func reconnect() {
        let engine = engine.engine
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        inputFormat = .init(commonFormat: outputFormat.commonFormat,
                            sampleRate: AVAudioSession.sharedInstance().sampleRate,
                            channels: outputFormat.channelCount,
                            interleaved: outputFormat.isInterleaved)!
        Self.logger.info("Creating Audio Mixer input format is: \(self.inputFormat!)")
        engine.attach(mixer)
        engine.connect(mixer, to: engine.outputNode, format: inputFormat)
        assert(engine.outputNode.inputFormat(forBus: 0).sampleRate == AVAudioSession.sharedInstance().sampleRate)
    }

    func addPlayer(identifier: SourceIDType, node: AVAudioSourceNode) throws {
        let engine = engine.engine
        engine.attach(node)
        engine.connect(node, to: mixer, format: self.inputFormat)
        Self.logger.info("(\(identifier)) Attached node: \(node.outputFormat(forBus: 0))")
    }

    func removePlayer(identifier: SourceIDType) {

        guard let element = elements.removeValue(forKey: identifier) else { return }
        Self.logger.info("(\(identifier)) Removing")

        // Dispose of the element's resources.
        if let engine = element.engine {
            engine.disconnectNodeInput(element)
            engine.detach(element)
        }
    }
}
