import AVFoundation

/// Plays audio samples out.
class AudioPlayer {
    private let engine: AVAudioEngine = .init()
    private var players: [UInt32: AVAudioPlayerNode] = [:]
    private var mixer: AVAudioMixerNode = .init()
    private let mixerFormat: AVAudioFormat

    private let fileWrite: Bool
    private var playPcm: AVAudioFile?

    /// Create a new `AudioPlayer`
    init(fileWrite: Bool) {
        do {
            mixerFormat = mixer.inputFormat(forBus: 0)
            engine.attach(mixer)
            engine.connect(mixer, to: engine.outputNode, format: mixerFormat)
            try engine.start()
            self.fileWrite = fileWrite
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    deinit {
        engine.stop()
    }

    func write(identifier: UInt32, buffer: AVAudioPCMBuffer) {
        guard mixerFormat.commonFormat == .pcmFormatFloat32 else {
            fatalError("Currently expecting output as F32")
        }

        let inputBuffer: AVAudioPCMBuffer
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            inputBuffer = buffer
        case .pcmFormatInt16:
            // Mixer cannot handle int16 -> float conversion.
            inputBuffer = buffer.asFloat()
        default:
            fatalError("Unsupported input format")
        }

        // Get the player node for this stream.
        var node: AVAudioPlayerNode? = players[identifier]
        if node == nil {
            node = createPlayer(identifier: identifier, inputFormat: inputBuffer.format)
        }

        if fileWrite {
            do {
                if playPcm == nil {
                    playPcm = try makeOutputFile(name: "play.wav", sampleFormat: inputBuffer.format)
                }
                try playPcm?.write(from: inputBuffer)
            } catch {
                fatalError(error.localizedDescription)
            }
        }

        // Play the buffer.
        node!.scheduleBuffer(inputBuffer)
    }

    private func createPlayer(identifier: UInt32, inputFormat: AVAudioFormat) -> AVAudioPlayerNode {
        guard players[identifier] == nil else { fatalError() }
        print("AudioPlayer => [\(identifier)] New player: \(inputFormat)")
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                fatalError(error.localizedDescription)
            }
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
