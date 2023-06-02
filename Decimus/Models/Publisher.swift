import AVFoundation
import Foundation

class Publisher: QPublisherDelegateObjC {
    let codecFactory: EncoderFactory

    init(audioFormat: AVAudioFormat) {
        self.codecFactory = .init(audioFormat: audioFormat)
    }

    func allocatePub(byNamespace quicrNamepace: String!) -> Any! {
        return Publication(codecFactory: codecFactory)
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
