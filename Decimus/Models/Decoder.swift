import AVFoundation
import CoreMedia
import Foundation

protocol Decoder {
    typealias DecodedCallback = (CMSampleBuffer, CMTimeValue, AVCaptureVideoOrientation?, Bool) -> Void
    var callback: DecodedCallback? {get set}

    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) throws
    mutating func registerCallback(callback: @escaping DecodedCallback)
}

extension Decoder {
    mutating func registerCallback(callback: @escaping DecodedCallback) {
        self.callback = callback
    }
}
