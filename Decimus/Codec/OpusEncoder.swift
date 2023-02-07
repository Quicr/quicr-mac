import CoreMedia
import AVFoundation

class OpusEncoder: Encoder {

    private var converter: AVAudioConverter?
    private let callback: EncodedDataCallback
    private let audio: AVAudioEngine = .init()

    init(callback: @escaping EncodedDataCallback) {
        self.callback = callback

//        // Tap the microphone.
//        audio.inputNode.installTap(onBus: 0,
//                                   bufferSize: 10,
//                                   format: audio.inputNode.inputFormat(forBus: 0)) { buffer, timestamp in
//
//            print("GOT SOME AUDIO DATA: \(timestamp)")
//            let opus: AVAudioBuffer = .init()
//            var error: NSError?
//
//            let conversion: AVAudioConverterOutputStatus? = self.converter?.convert(to: opus,
//                                                                               error: &error) { packetCount, outStatus in
//                print("WANTS TO CONVERT: \(packetCount)")
//                outStatus.pointee = .haveData
//                print("CONVERTED!")
//                return buffer
//            }
//            if conversion != nil {
//                print("HMM")
//                print(conversion!)
//            }
//
//            guard error == nil else { fatalError("Conversion failure") }
//        }
//
//        audio.prepare()
//        do {
//            try audio.start()
//        } catch {
//            fatalError("Audio engine failure: \(error.localizedDescription)")
//        }
    }

    func write(sample: CMSampleBuffer) {

        if converter == nil {

            DispatchQueue.main.sync {

                // Get the audio format of the native input.
                let cmAudioFormat = sample.formatDescription! as CMAudioFormatDescription
                let native: AVAudioFormat = .init(cmAudioFormatDescription: cmAudioFormat)

                // Target format is opus.
                // var opusSettings: [String: Any] = [:]
                // opusSettings[AVFormatIDKey] = kAudioFormatOpus
                // let opus: AVAudioFormat = .init(settings: opusSettings)!
                let opusFrameSize: UInt32 = 960
                let opusSampleRate: Float64 = 48000.0
                var opusDesc: AudioStreamBasicDescription = .init(mSampleRate: opusSampleRate,
                                                                  mFormatID: kAudioFormatOpus,
                                                                  mFormatFlags: 0,
                                                                  mBytesPerPacket: 0,
                                                                  mFramesPerPacket: opusFrameSize,
                                                                  mBytesPerFrame: 0,
                                                                  mChannelsPerFrame: 1,
                                                                  mBitsPerChannel: 0,
                                                                  mReserved: 0)
                // let opus: AVAudioFormat = .init(streamDescription: &opusDesc)!
                let opus: AVAudioFormat = .init(commonFormat: .pcmFormatInt16,
                                                sampleRate: opusSampleRate,
                                                channels: 1,
                                                interleaved: true)!

                // Create the converter.
                converter = .init(from: native, to: opus)
                guard converter != nil else { fatalError("Conversion not supported?") }

                // Respond with data when the converter wants it.
                let outputBuffer: AVAudioBuffer = .init()
                var error: NSError?
                converter!.convert(to: outputBuffer,
                                   error: &error) { packetCount, outStatus in
                    print("WANTS TO CONVERT: \(packetCount)")
                    outStatus.pointee = .haveData
                    print("CONVERTED!")
                    // return buffer
                    fatalError()
                }
            }
//            if conversion != nil {
//                print("HMM")
//                print(conversion!)
//            }
        }

        print("Got an audio sample")
//        let opus: AVAudioBuffer = .init()
//        var error: NSError?
//        let conversion: AVAudioConverterOutputStatus? = self.converter?.convert(to: opus,
//                                                                                error: &error) { _, outStatus in
//            outStatus.pointee = .haveData
//            print("CONVERTED!")
//            return buffer
//        }
//        if conversion != nil {
//            print(conversion!)
//        }
//
//        guard error == nil else { fatalError("Conversion failure") }

//        if converter == nil {
//            let cmAudioFormat = sample.formatDescription! as CMAudioFormatDescription
//            let native: AVAudioFormat = .init(cmAudioFormatDescription: cmAudioFormat)
//            var opusSettings: [String: Any] = [:]
//            opusSettings[AVFormatIDKey] = kAudioFormatOpus
//            let opus: AVAudioFormat = .init(settings: opusSettings)!
//            converter = .init(from: native, to: opus)!
//        }
//
//
//
//        var gotData = false
//        converter.convert(to: opus, error: &error, withInputFrom: { (_, outStatus) -> AVAudioBuffer? in
//            if gotData {
//                outStatus.pointee = .noDataNow
//                return nil
//            }
//            gotData = true
//            outStatus.pointee = .haveData
//            return inputBuffer
//        })
//
//        callback(sample)
    }
}
