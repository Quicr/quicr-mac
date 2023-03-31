import AVFoundation

/// Plays audio samples out.
class AudioPlayer {
    private let engine: AVAudioEngine = .init()
    private var players: [UInt32: AVAudioPlayerNode] = [:]
    private var mixer: AVAudioMixerNode = .init()
    private let mixerFormat: AVAudioFormat

    private let fileWrite: Bool
    private var playPcm: AVAudioFile?
    private let errorWriter: ErrorWriter

    /// Create a new `AudioPlayer`
    init(fileWrite: Bool, errorWriter: ErrorWriter) {
        self.errorWriter = errorWriter
        mixerFormat = mixer.inputFormat(forBus: 0)
        engine.attach(mixer)
        engine.connect(mixer, to: engine.outputNode, format: mixerFormat)
        engine.prepare()
        self.fileWrite = fileWrite
    }

    deinit {
        players.forEach { _, player in
            player.stop()
            engine.detach(player)
        }
        players.removeAll()
        engine.stop()
    }

    func write(identifier: UInt32, buffer: AVAudioPCMBuffer) {
        guard mixerFormat.commonFormat == .pcmFormatFloat32 else {
            errorWriter.writeError(message: "Currently expecting output as F32")
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
        var node: AVAudioPlayerNode? = players[identifier]
        if node == nil {
            do {
                node = try createPlayer(identifier: identifier, inputFormat: inputBuffer.format)
            } catch {
                errorWriter.writeError(message: error.localizedDescription)
                return
            }
        }

        if fileWrite {
            do {
                if playPcm == nil {
                    playPcm = try makeOutputFile(name: "play.wav", sampleFormat: inputBuffer.format)
                }
                try playPcm?.write(from: inputBuffer)
            } catch {
                errorWriter.writeError(message: error.localizedDescription)
                return
            }
        }

        // Play the buffer.
        node!.scheduleBuffer(inputBuffer)
    }

    private func createPlayer(identifier: UInt32, inputFormat: AVAudioFormat) throws -> AVAudioPlayerNode {
        guard players[identifier] == nil else { fatalError() }
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
            fatalError("AVAudioEngine expects these sample rates match. Out: \(outputRate) In: \(inputRate)")
        }

        players[identifier] = node
        return node
    }

    private func makeOutputFile(name: String, sampleFormat: AVAudioFormat) throws -> AVAudioFile {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).last
        return try .init(forWriting: dir!.appendingPathComponent(name),
                         settings: [
                            "AVFormatIdKey": kAudioFormatLinearPCM,
                            "AVSampleRateKey": sampleFormat.sampleRate,
                            "AVNumberOfChannelsKey": sampleFormat.channelCount
                         ],
                         commonFormat: sampleFormat.commonFormat,
                         interleaved: sampleFormat.isInterleaved)
    }
}
