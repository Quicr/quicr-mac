import Opus
import AVFoundation
import DequeModule

class LibOpusEncoder: Encoder {
    private var encoder: Opus.Encoder?
    private let callback: MediaCallback

    private var frameOffset: AVAudioFrameCount = 0
    private var encodeQueue: DispatchQueue = .init(label: "opus-encode", qos: .userInteractive)
    private var currentFormat: AVAudioFormat?
    private let opusFrameSize: AVAudioFrameCount = 480
    private let maxOpusEncodeBytes = 64000

    private var buffer: [Float] = []
    private var timestamps: [CMTime] = []

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

        if fileWrite {
            writeToFile(file: inputPcm, pcm: pcm)
        }

        // Write our samples to the buffer
        buffer.append(contentsOf: pcm.array())
        timestamps.append(sample.presentationTimeStamp)

        // Try to encode and empty the buffer
        while UInt32(buffer.count) / opusFrameSize >= 1 {
            tryEncode()
            buffer.removeSubrange(0...Int(opusFrameSize - 1))
            timestamps.removeFirst()
        }
    }

    private func tryEncode() {
        let collatedInput = buffer.withUnsafeMutableBufferPointer { bytes -> AVAudioPCMBuffer in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: currentFormat!.channelCount,
                    mDataByteSize: opusFrameSize * UInt32(MemoryLayout<Float>.size),
                    mData: bytes.baseAddress))
            return .init(pcmFormat: currentFormat!, bufferListNoCopy: &bufferList)!
        }

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
        let timeMs = timestamps.first!.convertScale(1000, method: .default)

        // Callback encoded data.
        encoded.withUnsafeBytes { opus in
            callback(.init(buffer: .init(start: opus.baseAddress, count: encodedBytes),
                           timestampMs: UInt32(timeMs.value)))
        }
    }

    private func writeToFile(file: AVAudioFile?, pcm: AVAudioPCMBuffer) {
        guard let file = file else { return }

        do {
            try file.write(from: pcm)
        } catch {
            fatalError(error.localizedDescription)
        }
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
