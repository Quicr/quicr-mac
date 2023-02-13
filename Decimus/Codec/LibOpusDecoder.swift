import Opus
import AVFoundation

class LibOpusDecoder: Decoder {

    let decoder: Opus.Decoder
    let callback: Encoder.EncodedBufferCallback

    init(callback: @escaping Encoder.EncodedBufferCallback) {
        self.callback = callback
        let format: AVAudioFormat = .init(opusPCMFormat: .int16, sampleRate: .opus48khz, channels: 1)!
        do {
            decoder = try .init(format: format)
        } catch {
            fatalError()
        }
    }

    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) {
        do {
            let unsafe: UnsafePointer<UInt8> = data.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let ubp: UnsafeBufferPointer<UInt8> = .init(start: unsafe, count: data.count)
            let outputFormat: AVAudioFormat = .init(commonFormat: .pcmFormatInt16,
                                                    sampleRate: Double(48000),
                                                    channels: 1,
                                                    interleaved: false)!
            let pcm: AVAudioPCMBuffer = .init(pcmFormat: outputFormat, frameCapacity: 1000)!
            try decoder.decode(ubp, to: pcm)
            let decodedBytes: Int = Int(pcm.frameLength * 2)
            guard pcm.mutableAudioBufferList.pointee.mNumberBuffers == 1 else { fatalError() }
//            pcm.int16ChannelData!.pointee.withMemoryRebound(to: UInt8.self, capacity: decodedBytes) { remapped in
//                let unsafeRawBufferPointer: UnsafeRawBufferPointer = .
//                
//                let buffer: MediaBuffer = .init(identifier: 0,
//                                                buffer: remapped,
//                                                length: Int(pcm.frameLength),
//                                                timestampMs: 0)
//                callback(buffer)
//            }

            // let sample = OpusDecoder.sampleFromAudio(buffer: pcm, timestamp: .invalid)
            print("Opus: Decoded \(pcm.frameLength)")
        } catch {
            print("Opus: Failed to decode")
        }
    }
}

































