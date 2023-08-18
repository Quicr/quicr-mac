import AVFoundation
import CoreAudio
import CTPCircularBuffer
import os

/// Plays audio samples out.
class FasterAVEngineAudioPlayer {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: FasterAVEngineAudioPlayer.self)
    )

    let inputFormat: AVAudioFormat
    private var engine: AVAudioEngine = .init()
    private var mixer: AVAudioMixerNode = .init()
    private let errorWriter: ErrorWriter
    private var elements: [SourceIDType: AVAudioSourceNode] = [:]

    /// Create a new `AudioPlayer`
    init(errorWriter: ErrorWriter, voiceProcessing: Bool) {
        self.errorWriter = errorWriter
        engine.attach(mixer)
        inputFormat = mixer.inputFormat(forBus: 0)

        Self.logger.info("Creating Audio Mixer input format is: \(self.inputFormat)")

        engine.connect(mixer, to: engine.outputNode, format: nil)
        if engine.outputNode.isVoiceProcessingEnabled != voiceProcessing {
            do {
                try engine.outputNode.setVoiceProcessingEnabled(voiceProcessing)
            } catch {
                Self.logger.error("Failed to set output voice processing: \(error.localizedDescription)")
                errorWriter.writeError("Failed to set output voice processing: \(error.localizedDescription)")
            }
        }
        engine.prepare()
    }

    deinit {
        engine.stop()

        for identifier in elements.keys {
            removePlayer(identifier: identifier)
        }
        elements.removeAll()

        engine.disconnectNodeInput(mixer)
        engine.detach(mixer)
    }

    func addPlayer(identifier: SourceIDType, node: AVAudioSourceNode) throws {
        Self.logger.info("(\(identifier)) Attaching node: \(node.outputFormat(forBus: 0))")
        engine.attach(node)
        engine.connect(node, to: mixer, format: nil)
        if !engine.isRunning {
            try engine.start()
        }
    }

    func removePlayer(identifier: SourceIDType) {

        guard let element = elements.removeValue(forKey: identifier) else { return }
        Self.logger.info("(\(identifier)) Removing")

        // Dispose of the element's resources.
        engine.disconnectNodeInput(element)
        engine.detach(element)
    }
}
