import AVFoundation
import CoreAudio
import CTPCircularBuffer

/// Plays audio samples out.
class FasterAVEngineAudioPlayer: AudioPlayer {
    let inputFormat: AVAudioFormat
    private var engine: AVAudioEngine = .init()
    private var mixer: AVAudioMixerNode = .init()
    private let errorWriter: ErrorWriter
    private var elements: [UInt64: SourceElement] = [:]

    /// Create a new `AudioPlayer`
    init(errorWriter: ErrorWriter) {
        self.errorWriter = errorWriter

        engine.attach(mixer)
        inputFormat = mixer.inputFormat(forBus: 0)
        print("[FasterAVEngineAudioPlayer] Creating. Mixer input format is: \(inputFormat)")
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
        let source: SourceElement? = elements[identifier]
        guard let source = source else {
            errorWriter.writeError(message: "Missing player for: \(identifier)")
            return
        }

        // Copy data into the source's input buffer.
        source.write(list: buffer.mutableAudioBufferList)
    }

    func addPlayer(identifier: UInt64, format: AVAudioFormat) {
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            self.errorWriter.writeError(message: "Couldn't start audio engine")
        }

        // Create a node for this source and add it to the mixer.
        let source: SourceElement = .init(format: format)
        print("[FasterAVAudioEngine] (\(identifier)) Creating element: \(format)")
        elements[identifier] = source
        engine.attach(source.sourceNode)
        engine.connect(source.sourceNode, to: mixer, format: nil)
    }

    func removePlayer(identifier: UInt64) {

        guard let element = elements.removeValue(forKey: identifier) else { return }
        print("[FasterAVAudioEngine] (\(identifier)) Removing")

        // Dispose of the element's resources.
        engine.disconnectNodeInput(element.sourceNode)
        engine.detach(element.sourceNode)
    }
}
