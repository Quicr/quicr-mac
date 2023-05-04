import AVFoundation
import CoreAudio
import CTPCircularBuffer

/// Plays audio samples out.
class FasterAVEngineAudioPlayer: AudioPlayer {
    private var engine: AVAudioEngine! = .init()
    private var mixer: AVAudioMixerNode! = .init()
    private let errorWriter: ErrorWriter
    private var players: [UInt32: AVAudioSourceNode] = [:]
    private var buffers: [UInt32: TPCircularBuffer] = [:]
    private var metrics: [UInt32: BufferMetrics] = [:]

    private struct BufferMetrics {
        var copyFails = 0
        var incompleteFrames = 0
        var reads = 0
        var copyAttempts = 0
    }

    /// Create a new `AudioPlayer`
    init(errorWriter: ErrorWriter) {
        self.errorWriter = errorWriter

        engine.attach(mixer)
        engine.connect(mixer, to: engine.outputNode, format: nil)
        engine.prepare()
    }

    deinit {
        engine.stop()

        for identifier in players.keys {
            removePlayer(identifier: identifier)
        }
        players.removeAll()

        engine.disconnectNodeInput(mixer)
        engine.detach(mixer)

        mixer = nil
        engine = nil
    }

    func write(identifier: UInt32, buffer: AVAudioPCMBuffer) {
        // Get the player node for this stream.
        var node: AVAudioSourceNode? = players[identifier]
        if node == nil {
            do {
                node = try createPlayer(identifier: identifier, inputFormat: buffer.format)
            } catch {
                errorWriter.writeError(message: error.localizedDescription)
                return
            }
        }

        // Get the buffer for this stream.
        let list = buffer.mutableAudioBufferList.pointee

        guard list.mNumberBuffers == 1 else {
            fatalError()
        }

        guard list.mBuffers.mDataByteSize > 0 else {
            fatalError()
        }

        var mutableList = list
        self.metrics[identifier]!.copyAttempts += 1
        let copied = TPCircularBufferCopyAudioBufferList(&buffers[identifier]!,
                                                         &mutableList,
                                                         nil,
                                                         kTPCircularBufferCopyAll,
                                                         nil)
        guard copied else {
            self.metrics[identifier]!.copyFails += 1
            return
        }
    }

    private func createPlayer(identifier: UInt32, inputFormat: AVAudioFormat) throws -> AVAudioSourceNode {
        guard players[identifier] == nil else { fatalError() }
        print("AudioPlayer => [\(identifier)] New player: \(inputFormat)")
        if !engine.isRunning {
            try engine.start()
        }

        // Create the circular buffer.
        buffers[identifier] = .init()
        let created = _TPCircularBufferInit(&buffers[identifier]!,
                                            1,
                                            MemoryLayout<TPCircularBuffer>.size)
        guard created else {
            fatalError()
        }

        var absd = inputFormat.streamDescription.pointee
        let node: AVAudioSourceNode = .init(format: inputFormat) { silence, timestamp, numFrames, data in

            // Fill the buffers as best we can.
            var copiedFrames: UInt32 = numFrames
            let mutableTimestamp = timestamp
            TPCircularBufferDequeueBufferListFrames(&self.buffers[identifier]!,
                                                    &copiedFrames,
                                                    data,
                                                    .init(mutating: mutableTimestamp),
                                                    &absd)
            self.metrics[identifier]!.reads += 1
            guard copiedFrames == numFrames else {
                // Ensure any incomplete data is pure silence.
                let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
                for buffer in buffers {
                    guard let dataPointer = buffer.mData else {
                        break
                    }
                    let discontinuityStartOffset = Int(copiedFrames * absd.mBytesPerFrame)
                    let numberOfSilenceBytes = Int((numFrames - copiedFrames) * absd.mBytesPerFrame)
                    guard discontinuityStartOffset + numberOfSilenceBytes == buffer.mDataByteSize else {
                        print("[FasterAVEngineAudioPlayer] Invalid buffers when calculating silence")
                        break
                    }
                    memset(dataPointer + discontinuityStartOffset, 0, Int(numberOfSilenceBytes))
                    let thisBufferSilence = numberOfSilenceBytes == buffer.mDataByteSize
                    let silenceSoFar = silence.pointee.boolValue
                    silence.pointee = .init(thisBufferSilence && silenceSoFar)
                    self.metrics[identifier]!.incompleteFrames += 1
                }
                return .zero
            }
            return .zero
        }
        engine.attach(node)
        engine.connect(node, to: mixer, format: nil)
        players[identifier] = node
        metrics[identifier] = .init()
        return node
    }

    func removePlayer(identifier: UInt32) {
        guard let player = players[identifier] else { return }
        print("Removing \(identifier)")

        engine.disconnectNodeInput(player)
        engine.detach(player)
        players.removeValue(forKey: identifier)

        var buffer = buffers.removeValue(forKey: identifier)!
        TPCircularBufferCleanup(&buffer)

        let metric = metrics.removeValue(forKey: identifier)!
        print("They had \(metric.copyFails)/\(metric.copyAttempts) copy fails")
        print("They had \(metric.incompleteFrames)/\(metric.reads) incomplete reads")
    }
}
