import AVFoundation
import CoreAudio
import CTPCircularBuffer
import os

/// Plays audio samples out.
class FasterAVEngineAudioPlayer {
    private static let logger = DecimusLogger(FasterAVEngineAudioPlayer.self)

    private let engine: DecimusAudioEngine
    private var mixer: AVAudioMixerNode = .init()
    private var elements: [SourceIDType: AVAudioSourceNode] = [:]
    
    private lazy var reconfigure: DecimusAudioEngine.ReconfigureEvent = { [weak self] in
        guard let self = self else { return }
        let engine = self.engine.engine

        // Reconnect the mixer and ensure the format.
        engine.connect(self.mixer, to: engine.outputNode, format: DecimusAudioEngine.format)
        assert(self.mixer.numberOfOutputs == 1)
        let mixerOutputFormat = self.mixer.outputFormat(forBus: 0)
        Self.logger.info("Connected mixer: \(mixerOutputFormat)")
        assert(mixerOutputFormat == DecimusAudioEngine.format)

        // Sanity check the output format.
        assert(engine.outputNode.numberOfInputs == 1)
        assert(engine.outputNode.isVoiceProcessingEnabled)
        assert(engine.outputNode.inputFormat(forBus: 0) == DecimusAudioEngine.format)

        // We shouldn't need to reconnect source nodes to the mixer,
        // as the format should not have changed.
        for element in self.elements {
            assert(element.value.numberOfOutputs == 1)
            let sourceOutputFormat = element.value.outputFormat(forBus: 0)
            assert(sourceOutputFormat == DecimusAudioEngine.format)
        }
    }

    /// Create a new `AudioPlayer`
    init(engine: DecimusAudioEngine) {
        self.engine = engine
        engine.engine.attach(mixer)
        reconfigure()
        engine.registerReconfigureInterest(id: "Player", callback: reconfigure)
    }

    deinit {
        for identifier in elements.keys {
            do {
                try removePlayer(identifier: identifier)
            } catch {
                Self.logger.critical(error.localizedDescription)
            }
        }
        elements.removeAll()

        engine.engine.detach(self.mixer)
        engine.unregisterReconfigureInterest(id: "Player")
    }

    /// Add a source node to this player, to be mixed with any others.
    /// - Parameter identifier: Identifier for this source.
    /// - Parameter node: The source node supplying audio.
    func addPlayer(identifier: SourceIDType, node: AVAudioSourceNode) throws {
        let engine = engine.engine
        engine.attach(node)
        engine.connect(node, to: mixer, format: DecimusAudioEngine.format)
        assert(node.numberOfOutputs == 1)
        assert(node.outputFormat(forBus: 0) == DecimusAudioEngine.format)
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
        self.engine.engine.detach(element)
        Self.logger.info("(\(identifier)) Removed player node")
    }
}
