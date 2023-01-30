import CoreGraphics
import CoreMedia
import SwiftUI

class Loopback: ApplicationModeBase {

    let localVideoStreamId: UInt32 = 1
    let localAudioStreamId: UInt32 = 99
    let localMirrorParticipants: UInt32 = 0

    override var root: AnyView {
        get { return .init(InCallView {}) }
        set { }
    }

    override func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {
        // Loopback: Write encoded data to decoder.
        do {
            try data.dataBuffer!.withUnsafeMutableBytes { ptr in
                let unsafe: UnsafePointer<UInt8> = .init(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self))
                var timestamp: CMTime = .init()
                do {
                    timestamp = try data.sampleTimingInfo(at: 0).presentationTimeStamp
                } catch {
                    print("[Loopback] Failed to get timestamp")
                }
                let timestampMs: UInt32 = UInt32(timestamp.seconds * 1000)
                pipeline!.decode(identifier: identifier,
                                 data: unsafe,
                                 length: data.dataBuffer!.dataLength,
                                 timestamp: timestampMs)
            }
        } catch {
            print("[Loopback] Failed to get bytes of encoded data")
        }
    }

    override func sendEncodedAudio(identifier: UInt32, data: CMSampleBuffer) {
        // Loopback: Write encoded data to decoder.
        var memory = data
        let address = withUnsafePointer(to: &memory, {UnsafeRawPointer($0)})
        pipeline!.decode(identifier: identifier,
                         data: address.assumingMemoryBound(to: UInt8.self),
                         length: 0,
                         timestamp: 0)
    }

    override func encodeCameraFrame(frame: CMSampleBuffer) {
        for id in localVideoStreamId...localMirrorParticipants + 1 {
            encodeSample(identifier: id, frame: frame, type: .video) {
                let size = frame.formatDescription!.dimensions
                pipeline!.registerEncoder(identifier: id, width: size.width, height: size.height)
            }
        }
    }

    override func encodeAudioSample(sample: CMSampleBuffer) {
        encodeSample(identifier: localAudioStreamId, frame: sample, type: .audio) {
            pipeline!.registerEncoder(identifier: localAudioStreamId)
        }
    }

    private func encodeSample(identifier: UInt32,
                              frame: CMSampleBuffer,
                              type: PipelineManager.MediaType,
                              register: () -> Void) {
        // Make a encoder for this stream.
        if pipeline!.encoders[identifier] == nil {
            register()

            // Since we're in loopback, we can make a decoder upfront too.
            pipeline!.registerDecoder(identifier: identifier, type: type)
        }

        // Write camera frame to pipeline.
        pipeline!.encode(identifier: identifier, sample: frame)
    }
}
