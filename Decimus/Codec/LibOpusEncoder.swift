import Opus
import AVFoundation

class LibOpusEncoder: Encoder {
    private var encoder: Opus.Encoder?
    private let callback: MediaCallback

    private var encodeQueue: DispatchQueue = .init(label: "opus-encode", qos: .userInteractive)
    private var currentFormat: AVAudioFormat?
    private let opusFrameSize: AVAudioFrameCount = 480
    private var encoded: Data = .init(count: 64000)

    private var buffer: [UInt8] = []
    private var timestamps: [CMTime] = []
    private var opusFrameSizeBytes: UInt32 = 0

    init(callback: @escaping MediaCallback) {
        self.callback = callback
    }

    private func createEncoder(formatDescription: CMFormatDescription) {
        // Initialize an encoder if we haven't already.
        let sampleFormat: AVAudioFormat = .init(cmAudioFormatDescription: formatDescription)
        if currentFormat != nil && currentFormat != sampleFormat {
            fatalError("Opus encoder can't change format")
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

        opusFrameSizeBytes = opusFrameSize * currentFormat!.streamDescription.pointee.mBytesPerFrame
    }

    func write(sample: CMSampleBuffer) {
        if encoder == nil {
            createEncoder(formatDescription: sample.formatDescription!)
        }

        // Write our samples to the buffer
        do {
            try sample.dataBuffer?.withUnsafeMutableBytes {
                buffer.append(contentsOf: $0)
            }
        } catch {
            fatalError("Failed to write samples to encoder buffer")
        }

        timestamps.append(sample.presentationTimeStamp)

        // Try to encode and empty the buffer
        while UInt32(buffer.count) >= opusFrameSizeBytes {
            tryEncode()

            buffer.removeSubrange(0...Int(opusFrameSizeBytes) - 1)
            if buffer.count > 0 && timestamps.count != 1 {
                timestamps.removeFirst()
            }
        }
    }

    private func tryEncode() {
        let pcm: AVAudioPCMBuffer
        do {
            pcm = try buffer.toPCM(frames: opusFrameSize, format: currentFormat!)
        } catch PcmBufferError.notEnoughData(requestedBytes: let requested, availableBytes: let available) {
            fatalError("Not enough data: \(requested)/\(available)")
        } catch {
            fatalError(error.localizedDescription)
        }

        // Encode to Opus.
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
}
