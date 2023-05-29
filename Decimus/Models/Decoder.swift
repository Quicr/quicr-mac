import AVFoundation
import CoreImage
import Foundation

protocol Decoder {
    func write(data: UnsafeRawBufferPointer, timestamp: UInt32)
}

protocol SampleDecoder: Decoder {
    typealias DecodedSampleCallback = (CIImage, CMTimeValue, AVCaptureVideoOrientation?, Bool) -> Void
    var callback: DecodedSampleCallback? {get set}

    mutating func registerCallback(callback: @escaping DecodedSampleCallback)
}

extension SampleDecoder {
    mutating func registerCallback(callback: @escaping DecodedSampleCallback) {
        self.callback = callback
    }
}

protocol BufferDecoder: Decoder {
    typealias DecodedBufferCallback = (_ buffer: AVAudioPCMBuffer, _ timestamp: CMTime) -> Void
    var callback: DecodedBufferCallback? {get set}
    var decodedFormat: AVAudioFormat {get}

    mutating func registerCallback(callback: @escaping DecodedBufferCallback)
}

extension BufferDecoder {
    mutating func registerCallback(callback: @escaping DecodedBufferCallback) {
        self.callback = callback
    }
}
