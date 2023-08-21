import AVFoundation
import CoreMedia
import Foundation

protocol Decoder {
    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) throws
}

protocol SampleDecoder: Decoder {
    typealias DecodedCallback = (CMSampleBuffer, CMTimeValue, AVCaptureVideoOrientation?, Bool) -> Void
    var callback: DecodedCallback? {get set}

    mutating func registerCallback(callback: @escaping DecodedCallback)
}

extension SampleDecoder {
    mutating func registerCallback(callback: @escaping DecodedCallback) {
        self.callback = callback
    }
}

protocol BufferDecoder: Decoder {
    typealias DecodedCallback = (_ buffer: AVAudioPCMBuffer, _ timestamp: CMTime) -> Void
    var callback: DecodedCallback? {get set}
    var decodedFormat: AVAudioFormat {get}

    mutating func registerCallback(callback: @escaping DecodedCallback)
}

extension BufferDecoder {
    mutating func registerCallback(callback: @escaping DecodedCallback) {
        self.callback = callback
    }
}
