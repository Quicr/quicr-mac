import CTPCircularBuffer
import AVFAudio
import CoreAudio

class SourceElement {

    struct Metrics {
        var copyFails = 0
        var copyAttempts = 0
    }

    var sourceNode: AVAudioSourceNode
    private var buffer: UnsafeMutablePointer<TPCircularBuffer> = .allocate(capacity: 1)
    private var asbd: UnsafePointer<AudioStreamBasicDescription>
    private var metrics: Metrics = .init()

    init(format: AVAudioFormat) {
        // Create the circular buffer with minimum size.
        let created = _TPCircularBufferInit(buffer,
                                            1,
                                            MemoryLayout<TPCircularBuffer>.size)
        guard created else {
            fatalError()
        }

        // Create the player node.
        asbd = format.streamDescription
        sourceNode = .init(format: format) { [buffer, asbd] silence, timestamp, numFrames, data in

            // Fill the buffers as best we can.
            var copiedFrames: UInt32 = numFrames
            TPCircularBufferDequeueBufferListFrames(buffer,
                                                    &copiedFrames,
                                                    data,
                                                    .init(mutating: timestamp),
                                                    asbd)
            guard copiedFrames == numFrames else {
                // Ensure any incomplete data is pure silence.
                let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
                for buffer in buffers {
                    guard let dataPointer = buffer.mData else {
                        break
                    }
                    let discontinuityStartOffset = Int(copiedFrames * asbd.pointee.mBytesPerFrame)
                    let numberOfSilenceBytes = Int((numFrames - copiedFrames) * asbd.pointee.mBytesPerFrame)
                    guard discontinuityStartOffset + numberOfSilenceBytes == buffer.mDataByteSize else {
                        print("[FasterAVEngineAudioPlayer] Invalid buffers when calculating silence")
                        break
                    }
                    memset(dataPointer + discontinuityStartOffset, 0, Int(numberOfSilenceBytes))
                    let thisBufferSilence = numberOfSilenceBytes == buffer.mDataByteSize
                    let silenceSoFar = silence.pointee.boolValue
                    silence.pointee = .init(thisBufferSilence && silenceSoFar)
                }
                return .zero
            }
            return .zero
        }
    }

    /// Write some data into this source node's input buffer.
    /// Single writer thread should call this.
    /// - Parameter list: Pointer to the audio data to copy.
    func write(list: UnsafePointer<AudioBufferList>) {

        // Ensure this buffer looks valid.
        guard list.pointee.mNumberBuffers == 1 else {
            fatalError()
        }
        guard list.pointee.mBuffers.mDataByteSize > 0 else {
            fatalError()
        }

        // Copy in.
        let copied = TPCircularBufferCopyAudioBufferList(buffer,
                                                         list,
                                                         nil,
                                                         kTPCircularBufferCopyAll,
                                                         nil)
        metrics.copyAttempts += 1
        guard copied else {
            metrics.copyFails += 1
            return
        }
    }

    deinit {
        sourceNode.reset()

        // Cleanup buffer.
        TPCircularBufferCleanup(buffer)

        // Report metrics on leave.
        print("They had \(metrics.copyFails)/\(metrics.copyAttempts) copy fails")
    }
}
