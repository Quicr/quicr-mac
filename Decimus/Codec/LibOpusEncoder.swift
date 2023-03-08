import Opus
import AVFoundation
import DequeModule

class LibOpusEncoder: Encoder {
    private var encoder: Opus.Encoder?
    private let callback: MediaCallback
    private var queue: Deque<(AVAudioPCMBuffer, CMTime)> = .init()
    private var frameOffset: AVAudioFrameCount = 0
    private var encodeQueue: DispatchQueue = .init(label: "opus-encode", qos: .userInteractive)
    private var currentFormat: AVAudioFormat?
    private let opusFrameSize: AVAudioFrameCount = 480
    private let maxOpusEncodeBytes = 64000

    // Debug file output.
    private let fileWrite: Bool
    private var inputPcm: AVAudioFile?
    private var collatedPcm: AVAudioFile?

    init(fileWrite: Bool, callback: @escaping MediaCallback) {
        self.fileWrite = fileWrite
        self.callback = callback
    }

    private func createEncoder(formatDescription: CMFormatDescription) {
        // Initialize an encoder if we haven't already.
        let sampleFormat: AVAudioFormat = .init(cmAudioFormatDescription: formatDescription)
        if currentFormat != nil && currentFormat != sampleFormat {
            fatalError("Opus encoder can't change format")
        }

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

    func write(sample: CMSampleBuffer) {
        if encoder == nil {
            createEncoder(formatDescription: sample.formatDescription!)
        }

        // Add the incoming PCM to the queue.
        let pcm: AVAudioPCMBuffer = .fromSample(sample: sample)
        queue.append((pcm, sample.presentationTimeStamp))

        if fileWrite {
            writeToFile(file: inputPcm, pcm: pcm)
        }

        tryEncode()
    }

    private func writeToFile(file: AVAudioFile?, pcm: AVAudioPCMBuffer) {
        guard let file = file else { return }

        do {
            try file.write(from: pcm)
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    private func tryEncode() {
        let (earliestTimestamp, collatedInput) = collateInputData()
        if earliestTimestamp == nil { return }

        // Write selected input to wav.
        if fileWrite {
            writeToFile(file: collatedPcm, pcm: collatedInput)
        }

        // Encode to Opus.
        var encoded: Data = .init(count: maxOpusEncodeBytes)
        var encodedBytes = 0
        do {
            encodedBytes = try encoder!.encode(collatedInput, to: &encoded)
        } catch {
             fatalError("Failed to encode opus: \(error). Format: \(currentFormat!)")
        }

        // Timestamp.
        let timeMs = earliestTimestamp!.convertScale(1000, method: .default)

        // Callback encoded data.
        encoded.withUnsafeBytes { opus in
            callback(.init(buffer: .init(start: opus, count: encodedBytes),
                           timestampMs: UInt32(timeMs.value)))
        }

        // We're not quite done, finish encoding.
        if queue.count > 1 { tryEncode() }
    }

    private func collateInputData() -> (CMTime?, AVAudioPCMBuffer) {
        // What do we need to encode?
        var requiredFrames = opusFrameSize
        let bytesPerFrame = currentFormat!.formatDescription.audioStreamBasicDescription!.mBytesPerFrame

        // Prepare storage for encoded data.
        let selectedInput: AVAudioPCMBuffer = .init(pcmFormat: currentFormat!, frameCapacity: requiredFrames)!
        var selectedInputDataOffset = 0

        var readIndex = 0

        // Collate input data.
        var earliestTimestamp: CMTime?
        while requiredFrames > 0 {
            guard !queue.isEmpty else {
                // Ran out of data, reset and wait for more.
                frameOffset = 0
                return (earliestTimestamp, selectedInput)
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
            } else {
                frameOffset += framesToTake
            }
        }

        if readIndex > 0 {
            for _ in 0...readIndex-1 {
                _ = queue.popFirst()
            }
        }

        return (earliestTimestamp, selectedInput)
    }

    private func makeOutputFiles(sampleFormat: AVAudioFormat) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).last
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
