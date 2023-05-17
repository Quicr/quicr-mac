import AVFoundation
import CoreAudio
import CTPCircularBuffer

/// Plays audio samples out.
class FasterAVEngineAudioPlayer: AudioPlayer {
    private var engine: AVAudioEngine = .init()
    private var mixer: AVAudioMixerNode = .init()
    private let errorWriter: ErrorWriter
    private var elements: [UInt64: SourceElement] = [:]

    /// Create a new `AudioPlayer`
    init(errorWriter: ErrorWriter) {
        self.errorWriter = errorWriter

        engine.attach(mixer)
        engine.connect(mixer, to: engine.outputNode, format: nil)
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

    func write(identifier: UInt64, buffer: AVAudioPCMBuffer) {
        // Get the source element for this identifier.
        let source: SourceElement
        let indeterminate: SourceElement? = elements[identifier]
        if indeterminate == nil {
            // TODO: Creation on demand will go away with prepare() / manifests.
            do {
                if !engine.isRunning {
                    try engine.start()
                }
            } catch {
                self.errorWriter.writeError(message: "Couldn't start audio engine")
            }

            // Create a node for this source and add it to the mixer.
            source = .init(format: buffer.format)
            elements[identifier] = source
            engine.attach(source.sourceNode)
            engine.connect(source.sourceNode, to: mixer, format: nil)
        } else {
            source = indeterminate!
        }

        // Copy data into the source's input buffer.
        source.write(list: buffer.mutableAudioBufferList)
    }

    func removePlayer(identifier: UInt64) {

        guard let element = elements.removeValue(forKey: identifier) else { return }
        print("[FasterAVAudioEngine] Removing \(identifier)")

        // Dispose of the element's resources.
        engine.disconnectNodeInput(element.sourceNode)
        engine.detach(element.sourceNode)
    }
}
