import Opus
import AVFoundation
import DequeModule

class LibOpusEncoder: Encoder {
    static let opusFrameSize: AVAudioFrameCount = 960

    private let encoder: Opus.Encoder
    private let callback: EncodedBufferCallback
    private let format: AVAudioFormat
    private var queue: Deque<(AVAudioPCMBuffer, CMTime)> = .init()
    private var readIndex = 0
    private var sampleOffset: AVAudioFrameCount = 0

    init(format: AVAudioFormat, callback: @escaping EncodedBufferCallback) {
        self.format = format
        self.callback = callback
        do {
            encoder = try .init(format: format)
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    func write(sample: CMSampleBuffer) {
        let sampleFormat: AVAudioFormat = .init(cmAudioFormatDescription: sample.formatDescription!)
        guard sampleFormat == format else { fatalError("Format mismatch") }
        guard sampleFormat.channelCount == 1 else { fatalError() }

        // Add the incoming PCM to the queue.
        let pcm: AVAudioPCMBuffer = .fromSample(sample: sample)
        queue.append((pcm, sample.presentationTimeStamp))

        // What do we need to encode?
        var requiredSamples = Self.opusFrameSize
        let bytesPerSample = sampleFormat.formatDescription.audioStreamBasicDescription!.mBytesPerFrame

        // Prepare storage for encoded data.
        let selectedInput: AVAudioPCMBuffer = .init(pcmFormat: sampleFormat, frameCapacity: requiredSamples)!
        selectedInput.frameLength = requiredSamples
        var selectedInputDataOffset = 0

        // Collate input data.
        var earliestTimestamp: CMTime?
        var toPop = 0
        while requiredSamples > 0 {
            guard !queue.isEmpty, queue.endIndex > readIndex else {
                // Ran out of data, reset and wait for more.
                readIndex = 0
                sampleOffset = 0
                return
            }

            // Get some data.
            let queued = queue[readIndex]
            let input: AVAudioPCMBuffer = queued.0
            if earliestTimestamp == nil {
                earliestTimestamp = queued.1
            }
            let samplesLeft = input.frameLength - sampleOffset
            let samplesToTake = min(requiredSamples, samplesLeft)
            let bytesToTake = samplesToTake * bytesPerSample

            // Copy the audio data to the encode buffer.
            let srcInt16 = input.int16ChannelData![0]
            let destInt16 = selectedInput.int16ChannelData![0]
            memcpy(destInt16 + selectedInputDataOffset, srcInt16, Int(bytesToTake))
            selectedInputDataOffset += Int(bytesToTake)
            requiredSamples -= samplesToTake

            if samplesToTake == samplesLeft {
                // Full read.
                readIndex += 1
                sampleOffset = 0
                toPop += 1
            } else {
                sampleOffset += samplesToTake
            }
        }

        // Remove any used up input buffers from the queue.
        if toPop > 0 {
            for _ in 0...toPop {
                _ = queue.popFirst()
            }
        }
        readIndex = 0

        // Encode to Opus.
        let maxOpusEncodeBytes = 1500
        var encoded: Data = .init(count: maxOpusEncodeBytes)
        var encodedBytes = 0
        do {
            encodedBytes = try encoder.encode(selectedInput, to: &encoded)
            print("Encoded: \(encodedBytes) bytes")
        } catch {
            fatalError("Failed to encode opus: \(error)")
        }

        // Timestamp.
        let timeMs = earliestTimestamp!.convertScale(1000, method: .default)

        // Callback encoded data.
        encoded.withUnsafeBytes { opus in
            callback(.init(identifier: 0,
                           buffer: .init(start: opus, count: encodedBytes),
                           timestampMs: UInt32(timeMs.value)))
        }
    }
}
