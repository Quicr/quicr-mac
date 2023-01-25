import CoreMedia
import AVFoundation

class OpusEncoder: Encoder {
    
    // TODO: Opus encode, for now just forward PCM.
    
    private var converter: AVAudioConverter? = nil
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
        
        // TODO: Setup the opus conversion session.
//        let output: AVAudioBuffer = .init()
//        var error: NSError?
//        let input: AVAudioConverterInputBlock = { (_, outStatus) -> AVAudioBuffer? in
//            return nil
//        }
        // converter?.convert(to: <#T##AVAudioBuffer#>, error: <#T##Error#>, withInputFromBlock: <#T##AVAudioConverterInputBlock#>)
    }
    
}
