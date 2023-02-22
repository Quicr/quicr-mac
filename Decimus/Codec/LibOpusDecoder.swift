import Opus
import AVFoundation

/// Decodes audio using libopus.
class LibOpusDecoder: Decoder {

    private let decoder: Opus.Decoder
    private let callback: PipelineManager.DecodedAudio
    private let format: AVAudioFormat
    private let fileWrite: Bool
    private var outputPcm: AVAudioFile?

    /// Create an opus decoder with the given input format.
    /// - Parameter format: The incoming opus format.
    /// - Parameter callback: A callback fired when decoded data becomes available.
    init(format: AVAudioFormat, fileWrite: Bool, callback: @escaping PipelineManager.DecodedAudio) {
        self.callback = callback
        self.format = format
        self.fileWrite = fileWrite
        do {
            guard format.isValidOpusPCMFormat else { fatalError() }
            decoder = try .init(format: format, application: .voip)
            if fileWrite {
                outputPcm = try makeOutputFile(sampleFormat: format)
            }
        } catch {
            fatalError("Opus => Unsupported format?")
        }
    }

    /// Write some encoded data to the decoder.
    /// - Parameter data: Pointer to some encoded opus data.
    /// - Parameter timestamp: Timestamp of this encoded data.
    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) {
        // Get to the right pointer type.
        let unsafe: UnsafePointer<UInt8> = data.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let ubp: UnsafeBufferPointer<UInt8> = .init(start: unsafe, count: data.count)

        // Create buffer for the decoded data.
        let decoded: AVAudioPCMBuffer = .init(pcmFormat: format,
                                              frameCapacity: .opusMax)!
        do {
            try decoder.decode(ubp, to: decoded)
            let timestamp: CMTime = .init(value: CMTimeValue(timestamp), timescale: 1000)
            if fileWrite {
                do {
                    try outputPcm?.write(from: decoded)
                } catch {
                    fatalError(error.localizedDescription)
                }
            }
            callback(decoded, timestamp)
        } catch {
            fatalError("Opus => Failed to decode: \(error)")
        }
    }

    private func makeOutputFile(sampleFormat: AVAudioFormat) throws -> AVAudioFile {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).last
        return try .init(forWriting: dir!.appendingPathComponent("output.wav"),
                         settings: [
                            "AVFormatIdKey": kAudioFormatLinearPCM,
                            "AVSampleRateKey": sampleFormat.sampleRate,
                            "AVNumberOfChannelsKey": sampleFormat.channelCount
                         ],
                         commonFormat: sampleFormat.commonFormat,
                         interleaved: sampleFormat.isInterleaved)
    }
}
