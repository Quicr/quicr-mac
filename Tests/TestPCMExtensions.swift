import XCTest
import AVFAudio
import Decimus

final class TestPCMExtensions: XCTestCase {
    func testBoundsCheck() throws {
        // Example data.
        var data: Array<UInt8> = .init(repeating: 0, count: 1)
        let format: AVAudioFormat = .init(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let expectedBytes = format.formatDescription.audioStreamBasicDescription!.mBytesPerFrame
        
        // Asking for more data than available should throw.
        XCTAssertThrowsError(try data.toPCM(frames: 1, format: format), "Expected bounds error") { error in
            let pcmError = error as? PcmBufferError
            XCTAssertNotNil(pcmError)
            guard case PcmBufferError.notEnoughData(requestedBytes: let bytes, availableBytes: let available) = pcmError! else {
                XCTFail()
                return
            }
            XCTAssertEqual(bytes, expectedBytes)
            XCTAssertEqual(1, available)
        }
    }
}
