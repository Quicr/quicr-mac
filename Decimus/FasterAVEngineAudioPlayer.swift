import AVFoundation
import CoreAudio
import CTPCircularBuffer

/// Plays audio samples out.
class FasterAVEngineAudioPlayer {
    let inputFormat: AVAudioFormat
    private unowned let engine: AVAudioEngine
    private var mixer: AVAudioMixerNode = .init()
    private let errorWriter: ErrorWriter
    private var elements: [SourceIDType: AVAudioSourceNode] = [:]

    /// Create a new `AudioPlayer`
    init(errorWriter: ErrorWriter, engine: AVAudioEngine) {
        self.errorWriter = errorWriter
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        inputFormat = .init(commonFormat: outputFormat.commonFormat,
                            sampleRate: AVAudioSession.sharedInstance().sampleRate,
                            channels: outputFormat.channelCount,
                            interleaved: outputFormat.isInterleaved)!
        print("[FasterAVEngineAudioPlayer] Creating. Mixer input format is: \(inputFormat)")
        engine.attach(mixer)
        engine.connect(mixer, to: engine.outputNode, format: inputFormat)
        assert(engine.outputNode.inputFormat(forBus: 0).sampleRate == AVAudioSession.sharedInstance().sampleRate)
        self.engine = engine
    }

    deinit {
        for identifier in elements.keys {
            removePlayer(identifier: identifier)
        }
        elements.removeAll()

        if let engine = mixer.engine {
            engine.disconnectNodeInput(mixer)
            engine.detach(mixer)
        }
    }

    func addPlayer(identifier: SourceIDType, node: AVAudioSourceNode) throws {
        engine.attach(node)
        engine.connect(node, to: mixer, format: self.inputFormat)
        print("[FasterAVAudioEngine] (\(identifier)) Attached node: \(node.outputFormat(forBus: 0))")
    }

    func removePlayer(identifier: SourceIDType) {

        guard let element = elements.removeValue(forKey: identifier) else { return }
        print("[FasterAVAudioEngine] (\(identifier)) Removing")

        // Dispose of the element's resources.
        if let engine = element.engine {
            engine.disconnectNodeInput(element)
            engine.detach(element)
        }
    }
}
