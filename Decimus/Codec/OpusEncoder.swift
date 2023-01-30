import CoreMedia
import AVFoundation

class OpusEncoder: Encoder {

    private var converter: AVAudioConverter?
    private let callback: EncodedDataCallback

    init(callback: @escaping EncodedDataCallback) {
        self.callback = callback
    }

    func write(sample: CMSampleBuffer) {
        if converter == nil {
            let cmAudioFormat = sample.formatDescription! as CMAudioFormatDescription
            initializeConverter(from: cmAudioFormat)
        }

        callback(sample)
    }

    func initializeConverter(from: CMAudioFormatDescription) {

        let native: AVAudioFormat = .init(cmAudioFormatDescription: from)
        var opusSettings: [String: Any] = [:]
        opusSettings[AVFormatIDKey] = kAudioFormatOpus
        let opus: AVAudioFormat = .init(settings: opusSettings)!
        converter = .init(from: native, to: opus)!

//        let output: AVAudioBuffer = .init()
//        var error: NSError?
//        let input: AVAudioConverterInputBlock = { (_, outStatus) -> AVAudioBuffer? in
//            return nil
//        }
        // converter?.convert(to: output, error: &error, withInputFromBlock: input)
    }

}
