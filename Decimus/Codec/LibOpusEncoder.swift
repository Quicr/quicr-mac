import Opus
import AVFoundation
import DequeModule

class LibOpusEncoder: Encoder {
    private let encoder: Opus.Encoder
    private let callback: EncodedBufferCallback
    private let format: AVAudioFormat
    private var queue: Deque<AVAudioPCMBuffer> = .init()
    private let opusFrameSize: AVAudioFrameCount = 240
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

        let pcm: AVAudioPCMBuffer = .fromSample(sample: sample)
        queue.append(pcm)

        var requiredSamples = opusFrameSize
        let bytesPerSample = sampleFormat.formatDescription.audioStreamBasicDescription!.mBytesPerFrame
        let toEncodeBytes: Int = Int(requiredSamples * bytesPerSample)
        var toEncode: Data = .init(count: toEncodeBytes)
        var toEncodeOffset = 0
        var toPop = 0
        while requiredSamples > 0 {
            guard !queue.isEmpty || queue.endIndex == readIndex else { return }

            let buffer: AVAudioPCMBuffer = queue[readIndex]
            let samplesLeft = buffer.frameLength - sampleOffset
            let samplesToTake = min(requiredSamples, samplesLeft)
            let bytesToTake = samplesToTake * bytesPerSample
            do {
                try toEncode.withUnsafeMutableBytes { dest in
                    memcpy(dest + toEncodeOffset, buffer.int16ChannelData!.pointee, Int(bytesToTake))
                }
            } catch {
                fatalError()
            }
            toEncodeOffset += Int(bytesToTake)
            requiredSamples -= samplesToTake

            if samplesToTake == samplesLeft {
                // Full read.
                readIndex += 1
                toPop += 1
                sampleOffset = 0
            } else {
                sampleOffset += samplesToTake
            }
        }

        if toPop > 0 {
            for pop in 0...toPop {
                _ = queue.popFirst()
            }
        }
        readIndex = 0

        // Make PCM buffer with this data.
        let encodeBuffer: AVAudioPCMBuffer = .init(pcmFormat: sampleFormat, frameCapacity: opusFrameSize)!
        toEncode.withUnsafeBytes { ptr in
            memcpy(encodeBuffer.int16ChannelData!.pointee, ptr, toEncodeBytes)
        }
        encodeBuffer.frameLength = opusFrameSize

        var encoded: Data = .init(count: 1500)
        var encodedCount = 0
        do {
            encodedCount = try encoder.encode(encodeBuffer, to: &encoded)
            print("Encoded: \(encodedCount)")
        } catch {
            fatalError("Failed to encode opus: \(error)")
        }
        
        encoded.withUnsafeBytes { ptr in
            let ptr: UnsafeRawBufferPointer = .init(start: ptr, count: encodedCount)
            let mediaBuffer: MediaBuffer = .init(identifier: 0, buffer: ptr, timestampMs: 0)
            callback(mediaBuffer)
        }
    }
}
