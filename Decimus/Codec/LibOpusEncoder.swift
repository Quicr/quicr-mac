import Opus
import AVFoundation
import DequeModule

class LibOpusEncoder: Encoder {
    private var encoder: Opus.Encoder?
    private let callback: EncodedBufferCallback
    private var queue: Deque<(AVAudioPCMBuffer, CMTime)> = .init()
    private var readIndex = 0
    private var frameOffset: AVAudioFrameCount = 0
    private var encodeQueue: DispatchQueue = .init(label: "opus-encode", qos: .userInteractive)
    private var currentFormat: AVAudioFormat?

    private var samplesHit = 0
    private var encodesDone = 0
    private let opusFrameSize: AVAudioFrameCount = 960

    // Debug file output.
    private let fileWrite: Bool
    private var inputPcm: AVAudioFile?
    private var collatedPcm: AVAudioFile?

    init(fileWrite: Bool, callback: @escaping EncodedBufferCallback) {
        self.fileWrite = fileWrite
        self.callback = callback
    }

    func write(sample: CMSampleBuffer) {
        samplesHit += 1

        // Initialize an encoder if we haven't already.
        let sampleFormat: AVAudioFormat = .init(cmAudioFormatDescription: sample.formatDescription!)
        if currentFormat != nil && currentFormat != sampleFormat {
            fatalError("Opus encoder can't change format")
        }
        if encoder == nil {
            if fileWrite {
                makeOutputFiles(sampleFormat: sampleFormat)
            }
            currentFormat = sampleFormat
            // Only the type of the incoming format is important for opus.
            // Encoder is safe to always be 2 channel @ 48kHz.
            let type: AVAudioFormat.OpusPCMFormat
            switch sampleFormat.commonFormat {
            case .pcmFormatFloat32:
                type = .float32
                print("Float")
            case .pcmFormatInt16:
                type = .int16
                print("Int")
            default:
                fatalError()
            }
            let opusFormat: AVAudioFormat = .init(opusPCMFormat: type,
                                                  sampleRate: .opus48khz,
                                                  channels: sampleFormat.channelCount)!
            do {
                encoder = try .init(format: opusFormat, application: .voip)
            } catch {
                fatalError(error.localizedDescription)
            }
        }

        // Add the incoming PCM to the queue.
        let pcm: AVAudioPCMBuffer = .fromSample(sample: sample)

        if fileWrite {
            do {
                try inputPcm!.write(from: pcm)
            } catch {
                fatalError(error.localizedDescription)
            }
        }
        queue.append((pcm, sample.presentationTimeStamp))
        tryEncode(format: sampleFormat)
    }

    private func tryEncode(format: AVAudioFormat) {
        guard self.currentFormat == format else {fatalError()}

        // What do we need to encode?
        var requiredFrames = opusFrameSize
        let bytesPerFrame = format.formatDescription.audioStreamBasicDescription!.mBytesPerFrame

        // Prepare storage for encoded data.
        let selectedInput: AVAudioPCMBuffer = .init(pcmFormat: format, frameCapacity: requiredFrames)!
        var selectedInputDataOffset = 0

        // Collate input data.
        var earliestTimestamp: CMTime?
        var toPop = 0
        while requiredFrames > 0 {
            guard !queue.isEmpty, queue.endIndex > readIndex else {
                // Ran out of data, reset and wait for more.
                readIndex = 0
                frameOffset = 0
                return
            }

            // Get some data.
            let queued = queue[readIndex]
            let input: AVAudioPCMBuffer = queued.0
            if earliestTimestamp == nil {
                earliestTimestamp = queued.1
            }
            let framesLeft = input.frameLength - frameOffset
            let framesToTake = min(requiredFrames, framesLeft)
            let bytesToTake: Int = .init(framesToTake * bytesPerFrame)
            let inputDataOffset: Int = .init(frameOffset * bytesPerFrame)

            // Copy the audio data to the encode buffer.
            let src: UnsafeRawPointer
            let dest: UnsafeMutableRawPointer
            if input.format.commonFormat == .pcmFormatInt16 {
                src = .init(input.int16ChannelData![0]).advanced(by: inputDataOffset)
                dest = .init(selectedInput.int16ChannelData![0]).advanced(by: selectedInputDataOffset)
            } else if input.format.commonFormat == .pcmFormatFloat32 {
                src = .init(input.floatChannelData![0]).advanced(by: inputDataOffset)
                dest = .init(selectedInput.floatChannelData![0]).advanced(by: selectedInputDataOffset)
            } else {
                fatalError()
            }
            dest.copyMemory(from: src, byteCount: bytesToTake)

            // Update offsets to reflect data capture.
            selectedInput.frameLength += framesToTake
            selectedInputDataOffset += bytesToTake
            requiredFrames -= framesToTake

            if framesToTake == framesLeft {
                // Full read.
                readIndex += 1
                frameOffset = 0
                toPop += 1
            } else {
                frameOffset += framesToTake
            }
        }

        // Remove any used up input buffers from the queue.
        if toPop > 0 {
            for _ in 0...toPop-1 {
                _ = queue.popFirst()
            }
        }
        readIndex = 0

        // Write selected input to wav.
        if fileWrite {
            do {
                try collatedPcm!.write(from: selectedInput)
            } catch {
                fatalError(error.localizedDescription)
            }
        }

        // Encode to Opus.
        let maxOpusEncodeBytes = 64000
        var encoded: Data = .init(count: maxOpusEncodeBytes)
        var encodedBytes = 0
        do {
            encodedBytes = try encoder!.encode(selectedInput, to: &encoded)
        } catch {
            fatalError("Failed to encode opus: \(error). Format: \(format)")
        }
        encodesDone += 1

        // Timestamp.
        let timeMs = earliestTimestamp!.convertScale(1000, method: .default)
        // Callback encoded data.
        encoded.withUnsafeBytes { opus in
            callback(.init(identifier: 0,
                           buffer: .init(start: opus, count: encodedBytes),
                           timestampMs: UInt32(timeMs.value)))
            print("Delta: \(samplesHit - encodesDone)")
        }
    }

    private func makeOutputFiles(sampleFormat: AVAudioFormat) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).last
        let file = dir!.appendingPathComponent("collated.wav")
        FileManager.default.createFile(atPath: file.path(), contents: nil)
        do {
            inputPcm = try .init(forWriting: dir!.appendingPathComponent("input.wav"),
                                 settings: [
                                    "AVFormatIdKey": kAudioFormatLinearPCM,
                                    "AVSampleRateKey": sampleFormat.sampleRate,
                                    "AVNumberOfChannelsKey": sampleFormat.channelCount
                                 ],
                                 commonFormat: sampleFormat.commonFormat,
                                 interleaved: sampleFormat.isInterleaved)
            collatedPcm = try .init(forWriting: dir!.appendingPathComponent("collated.wav"),
                                    settings: [
                                        "AVFormatIdKey": kAudioFormatLinearPCM,
                                        "AVSampleRateKey": sampleFormat.sampleRate,
                                        "AVNumberOfChannelsKey": sampleFormat.channelCount
                                    ],
                                    commonFormat: sampleFormat.commonFormat,
                                    interleaved: sampleFormat.isInterleaved)
        } catch {
            fatalError(error.localizedDescription)
        }
    }
}
