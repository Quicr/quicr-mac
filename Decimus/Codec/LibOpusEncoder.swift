// import Opus
import AVFoundation
import Copus

class LibOpusEncoder: Encoder {
    private let encoder: OpaquePointer
    internal var callback: EncodedBufferCallback?

    private var encodeQueue: DispatchQueue = .init(label: "opus-encode", qos: .userInteractive)
    private let opusFrameSize: AVAudioFrameCount = 480
    private var encoded: UnsafeMutableRawBufferPointer = .allocate(byteCount: 64000,
                                                                   alignment: MemoryLayout<UInt8>.alignment)

    private var buffer: [UInt8] = []
    private var timestamps: [UInt32] = []
    private var opusFrameSizeBytes: UInt32 = 0

    init() {
        // Only the type of the incoming format is important for opus.
        // Encoder is safe to always be 2 channel @ 48kHz.
        var error: Int32 = 0
        encoder = opus_encoder_create(48000, 1, OPUS_APPLICATION_VOIP, &error)
        guard error == .zero else { fatalError("\(error)") }
        // TODO: Assuming 16bit int.
        opusFrameSizeBytes = opusFrameSize * 2 * 1
    }

    func write(data: MediaBuffer) {

        // swiftlint:disable force_cast
        let format = data.userData! as! AVAudioFormat
        // swiftlint:enable force_cast
        guard format.commonFormat == .pcmFormatInt16 else { fatalError() }

        // Write our samples to the buffer
        data.buffer.withUnsafeBytes {
            buffer.append(contentsOf: $0)
        }

        timestamps.append(data.timestampMs)

        // Try to encode and empty the buffer
        while UInt32(buffer.count) >= opusFrameSizeBytes {
            tryEncode(format: format)

            buffer.removeSubrange(0...Int(opusFrameSizeBytes) - 1)
            if buffer.count > 0 && timestamps.count != 1 {
                timestamps.removeFirst()
            }
        }
    }

    private func tryEncode(format: AVAudioFormat) {
        guard let callback = callback else { fatalError("Callback not set for decoder") }

        let pcm: AVAudioPCMBuffer
        do {
            pcm = try buffer.toPCM(frames: opusFrameSize, format: format)
        } catch PcmBufferError.notEnoughData(requestedBytes: let requested, availableBytes: let available) {
            fatalError("Not enough data: \(requested)/\(available)")
        } catch {
            fatalError(error.localizedDescription)
        }

        // Encode to Opus.
        var encodedBytes = opus_encode(encoder,
                                       pcm.int16ChannelData!.pointee,
                                       Int32(opusFrameSize),
                                       encoded.baseAddress!,
                                       opus_int32(encoded.count))

        // Callback encoded data.
        encoded.withUnsafeBytes { bytes in
            callback(.init(buffer: .init(start: bytes.baseAddress, count: Int(encodedBytes)),
                           timestampMs: timestamps.first!, userData: nil))
        }
    }

    deinit {
        opus_encoder_destroy(encoder)
    }
}
