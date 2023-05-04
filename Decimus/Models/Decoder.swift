import AVFoundation
import CoreImage
import Foundation

protocol Decoder {
    func write(data: UnsafeRawBufferPointer, timestamp: UInt32)
}

protocol SampleDecoder: Decoder {
    typealias DecodedSampleCallback = (CIImage, CMTimeValue, AVCaptureVideoOrientation?, Bool) -> Void
    var callback: DecodedSampleCallback {get}

    func registerCallback(callback: @escaping DecodedSampleCallback)
}

protocol BufferDecoder: Decoder {
    typealias DecodedBufferCallback = (_ buffer: AVAudioPCMBuffer, _ timestamp: CMTime) -> Void
    var callback: DecodedBufferCallback {get}

    func registerCallback(callback: @escaping DecodedBufferCallback)
}
