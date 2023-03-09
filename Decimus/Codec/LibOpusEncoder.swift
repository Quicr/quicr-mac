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

    private var buffer: [UInt8] = []
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
        buffer.append(contentsOf: pcm.bytes())
        timestamps.append(sample.presentationTimeStamp)

        let opusFrameSizeBytes = opusFrameSize * currentFormat!.streamDescription.pointee.mBytesPerFrame

        // Try to encode and empty the buffer
        while UInt32(buffer.count) * currentFormat!.channelCount / opusFrameSizeBytes >= 1 {
            tryEncode()

            buffer.removeSubrange(0...Int(opusFrameSizeBytes) - 1)
            if buffer.count > 0 && timestamps.count != 1 {
                timestamps.removeFirst()
            }
        }
    }

    private func tryEncode() {
        let pcm = buffer.toPCM(size: opusFrameSize, format: currentFormat!)

        // Write selected input to wav.
        if fileWrite {
            writeToFile(file: collatedPcm, pcm: pcm)
        }

        // Encode to Opus.
        var encoded: Data = .init(count: maxOpusEncodeBytes)
        var encodedBytes = 0
        do {
            encodedBytes = try encoder!.encode(pcm, to: &encoded)
        } catch {
            fatalError("Failed to encode opus: \(error). Format: \(currentFormat!)")
        }

        // Timestamp.
        let timeMs = timestamps.first!.convertScale(1000, method: .default)

        // Callback encoded data.
        encoded.withUnsafeBytes { bytes in
            callback(.init(buffer: .init(start: bytes.baseAddress, count: encodedBytes),
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
