import XCTest
import Decimus
import AVFoundation

final class TestAudioUnitHelpers: XCTestCase {
    func testAsbdEquality() throws {
        // Example data.
        var format: AVAudioFormat = .init(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        var match: AVAudioFormat = .init(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        var mismatch: AVAudioFormat = .init(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false)!

        XCTAssertTrue(format.streamDescription.pointee == match.streamDescription.pointee)
        XCTAssertFalse(format.streamDescription.pointee == mismatch.streamDescription.pointee)
    }
}
