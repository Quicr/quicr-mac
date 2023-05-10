import AVFoundation
import CTPCircularBuffer
import CoreAudio

class AudioUnitPlayer: AudioPlayer {

    // TODO: Mixer support.

    private var buffer: TPCircularBuffer = .init()
    private var inputFormat: AudioStreamBasicDescription
    private var incompleteFrames: Int = 0
    private var copyFails: Int = 0
    private var copyAttempts: Int = 0
    private var reads: Int = 0

    init(audioUnit: AudioUnit, inputFormat: AudioStreamBasicDescription) throws {
        // Create the circular buffer.
        let created = _TPCircularBufferInit(&buffer,
                                            1,
                                            MemoryLayout.size(ofValue: buffer))
        guard created else {
            fatalError()
        }

        self.inputFormat = try audioUnit.setFormat(desired: inputFormat, microphone: false)
        if self.inputFormat != inputFormat {
            fatalError()
        }
        print("[AudioUnitPlayer] Input format is: \(self.inputFormat)")

        // Callback to pass data for playout.
        let playback: AURenderCallback = { ref, _, timestamp, _, numFrames, data in
            guard data != nil else { fatalError("??") }

            // Get back reference to the player.
            let auPlayer = Unmanaged<AudioUnitPlayer>.fromOpaque(ref).takeUnretainedValue()

            // Fill the buffers as best we can.
            var copiedFrames: UInt32 = numFrames
            let mutableTimestamp = timestamp
            TPCircularBufferDequeueBufferListFrames(&auPlayer.buffer,
                                                    &copiedFrames,
                                                    data,
                                                    .init(mutating: mutableTimestamp),
                                                    &auPlayer.inputFormat)
            auPlayer.reads += 1
            guard copiedFrames == numFrames else {
                // Ensure any incomplete data is pure silence.
                let buffers: UnsafeMutableAudioBufferListPointer = .init(data!)
                for buffer in buffers {
                    guard let dataPointer = buffer.mData else {
                        break
                    }
                    let discontinuityStartOffset = Int(copiedFrames * auPlayer.inputFormat.mBytesPerFrame)
                    let numberOfSilenceBytes = Int((numFrames - copiedFrames) * auPlayer.inputFormat.mBytesPerFrame)
                    guard discontinuityStartOffset + numberOfSilenceBytes == buffer.mDataByteSize else {
                        print("[AudioUnitPlayer] Invalid buffers when calculating silence")
                        break
                    }
                    memset(dataPointer + discontinuityStartOffset, 0, Int(numberOfSilenceBytes))
                }
                auPlayer.incompleteFrames += 1
                return .zero
            }
            return .zero
        }

        // Bind the output callback.
        var outputCallback: AURenderCallbackStruct = .init(inputProc: playback,
                                                     inputProcRefCon: Unmanaged.passRetained(self).toOpaque())
        let setOutputCallback = AudioUnitSetProperty(audioUnit,
                                               kAudioUnitProperty_SetRenderCallback,
                                               kAudioUnitScope_Input,
                                               0,
                                               &outputCallback,
                                               UInt32(MemoryLayout.size(ofValue: outputCallback)))
        guard setOutputCallback == .zero else {
            throw setOutputCallback
        }
    }

    func write(identifier: UInt64, buffer: AVAudioPCMBuffer) {
        let list = buffer.mutableAudioBufferList.pointee
        let format = buffer.format.streamDescription.pointee

        guard list.mNumberBuffers == 1 else {
            fatalError()
        }

        guard format == self.inputFormat else {
            fatalError("This needs to be converted.\nExpected: \(self.inputFormat)\nGot: \(format)")
        }

        guard list.mBuffers.mDataByteSize > 0 else {
            fatalError()
        }

        var mutableList = list
        copyAttempts += 1
        let copied = TPCircularBufferCopyAudioBufferList(&self.buffer,
                                                         &mutableList,
                                                         nil,
                                                         kTPCircularBufferCopyAll,
                                                         nil)
        guard copied else {
            copyFails += 1
            return
        }
    }

    func removePlayer(identifier: UInt64) {
        print("Please remove: \(identifier)")
        print("Incomplete reads: \(incompleteFrames)/\(reads)")
        print("Copy fails: \(copyFails)/\(copyAttempts)")
    }
}
