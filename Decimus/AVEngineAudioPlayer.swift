import AVFoundation

/// Plays audio samples out.
class AVEngineAudioPlayer: AudioPlayer {
    var inputFormat: AVAudioFormat
    private var engine: AVAudioEngine! = .init()
    private var mixer: AVAudioMixerNode! = .init()
    private let errorWriter: ErrorWriter
    private var players: [UInt64: AVAudioPlayerNode] = [:]

    /// Create a new `AudioPlayer`
    init(errorWriter: ErrorWriter) {
        self.errorWriter = errorWriter

        inputFormat = mixer.inputFormat(forBus: 0)
        engine.attach(mixer)
        engine.connect(mixer, to: engine.outputNode, format: nil)
        engine.prepare()
    }

    deinit {
        players.forEach { _, player in
            player.stop()
        }
        engine.stop()

        players.forEach { _, player in
            engine.disconnectNodeInput(player)
            engine.detach(player)
        }
        players.removeAll()

        engine.disconnectNodeInput(mixer)
        engine.detach(mixer)

        mixer = nil
        engine = nil
    }

    func addPlayer(identifier: UInt64, format: AVAudioFormat) {
        guard players[identifier] == nil else {
            errorWriter.writeError(message: "Audio player for: \(identifier) already exists")
            return
        }
        do {
            players[identifier] = try createPlayer(identifier: identifier, inputFormat: format)
        } catch {
            errorWriter.writeError(message: "Failed to create audio player: \(error)")
        }
    }

    func write(identifier: UInt64, buffer: AVAudioPCMBuffer) {
        guard inputFormat.commonFormat == buffer.format.commonFormat else {
            errorWriter.writeError(message: "Audio format mismatch")
            return
        }

        let inputBuffer: AVAudioPCMBuffer
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            inputBuffer = buffer
        case .pcmFormatInt16:
            // Mixer cannot handle int16 -> float conversion.
            inputBuffer = buffer.asFloat()
        default:
            errorWriter.writeError(message: "Unsupported input format")
            return
        }

        // Get the player node for this stream.
        var node: AVAudioPlayerNode = players[identifier]!

        // Play the buffer.
        node.scheduleBuffer(inputBuffer)
    }

    private func createPlayer(identifier: UInt64, inputFormat: AVAudioFormat) throws -> AVAudioPlayerNode {
        print("AudioPlayer => [\(identifier)] New player: \(inputFormat)")
        if !engine.isRunning {
            try engine.start()
        }

        let node: AVAudioPlayerNode = .init()
        engine.attach(node)
        engine.connect(node, to: mixer, format: inputFormat)
        node.play()

        let inputRate = inputFormat.sampleRate
        let outputRate = node.outputFormat(forBus: 0).sampleRate
        guard outputRate == inputRate else {
            throw "AVAudioEngine expects these sample rates match. Out: \(outputRate) In: \(inputRate)"
        }

        return node
    }

    func removePlayer(identifier: UInt64) {
        guard let player = players[identifier] else { return }

        player.stop()
        engine.disconnectNodeInput(player)
        engine.detach(player)
        players.removeValue(forKey: identifier)
    }
}
