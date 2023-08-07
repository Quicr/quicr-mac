import AVFoundation
import CoreAudio
import CTPCircularBuffer

/// Plays audio samples out.
class FasterAVEngineAudioPlayer {
    let inputFormat: AVAudioFormat
    private let engine: AVAudioEngine
    private var mixer: AVAudioMixerNode = .init()
    private let errorWriter: ErrorWriter
    private var elements: [SourceIDType: AVAudioSourceNode] = [:]

    /// Create a new `AudioPlayer`
    init(engine: AVAudioEngine, errorWriter: ErrorWriter) {
        self.engine = engine
        self.errorWriter = errorWriter
        engine.attach(mixer)
        inputFormat = mixer.inputFormat(forBus: 0)
        print("[FasterAVEngineAudioPlayer] Creating. Mixer input format is: \(inputFormat)")
        engine.connect(mixer, to: engine.outputNode, format: nil)
    }

    deinit {
        for identifier in elements.keys {
            removePlayer(identifier: identifier)
        }
        elements.removeAll()

        engine.disconnectNodeInput(mixer)
        engine.detach(mixer)
    }

    func addPlayer(identifier: SourceIDType, node: AVAudioSourceNode) throws {
        print("[FasterAVAudioEngine] (\(identifier)) Attaching node: \(node.outputFormat(forBus: 0))")
        engine.attach(node)
        engine.connect(node, to: mixer, format: nil)
    }

    func removePlayer(identifier: SourceIDType) {

        guard let element = elements.removeValue(forKey: identifier) else { return }
        print("[FasterAVAudioEngine] (\(identifier)) Removing")

        // Dispose of the element's resources.
        engine.disconnectNodeInput(element)
        engine.detach(element)
    }
}
