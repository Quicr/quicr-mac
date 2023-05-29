import AVFoundation
import CTPCircularBuffer
import CoreAudio

class AudioUnitPlayer: AudioPlayer {
    var inputFormat: AVAudioFormat

    private var buffer: TPCircularBuffer = .init()
    private var incompleteFrames: Int = 0
    private var copyFails: Int = 0
    private var copyAttempts: Int = 0
    private var reads: Int = 0
    private let audioUnit: AudioUnit

    init(audioUnit: AudioUnit) throws {
        self.audioUnit = audioUnit
        var inputAsbd = try audioUnit.getFormat(microphone: false)
        self.inputFormat = .init(streamDescription: &inputAsbd)!

        // Create the circular buffer.
        let created = _TPCircularBufferInit(&buffer,
                                            1,
                                            MemoryLayout.size(ofValue: buffer))
        guard created else {
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
            var asbd = auPlayer.inputFormat.streamDescription.pointee
            TPCircularBufferDequeueBufferListFrames(&auPlayer.buffer,
                                                    &copiedFrames,
                                                    data,
                                                    .init(mutating: mutableTimestamp),
                                                    &asbd)
            auPlayer.reads += 1
            guard copiedFrames == numFrames else {
                // Ensure any incomplete data is pure silence.
                let buffers: UnsafeMutableAudioBufferListPointer = .init(data!)
                for buffer in buffers {
                    guard let dataPointer = buffer.mData else {
                        break
                    }
                    let discontinuityStartOffset = Int(copiedFrames * asbd.mBytesPerFrame)
                    let numberOfSilenceBytes = Int((numFrames - copiedFrames) * asbd.mBytesPerFrame)
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

    func addPlayer(identifier: UInt64, format: AVAudioFormat) {
        // TODO: Player & mixer support.
    }

    func write(identifier: UInt64, buffer: AVAudioPCMBuffer) {
        let list = buffer.mutableAudioBufferList.pointee
        if !buffer.format.equivalent(other: self.inputFormat) {
            // Try and change the format to match.
            do {
                var asbd = try self.audioUnit.setFormat(desired: buffer.format.streamDescription.pointee,
                                                        microphone: false)
                self.inputFormat = .init(streamDescription: &asbd)!
            } catch {
                print("Couldn't update input format")
                return
            }
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
