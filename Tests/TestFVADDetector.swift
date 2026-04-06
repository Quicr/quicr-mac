// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import XCTest
import AVFAudio

final class TestFVADDetector: XCTestCase {

    private let sampleRate: Double = 48000
    private let frameLength: AVAudioFrameCount = 960 // 20ms at 48kHz

    private func makeBuffer(silence: Bool) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: self.sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: self.frameLength)!
        buffer.frameLength = self.frameLength
        if silence {
            // Zero-fill = silence.
            memset(buffer.floatChannelData![0], 0, Int(self.frameLength) * MemoryLayout<Float>.size)
        } else {
            // Generate a 440Hz sine wave at full scale.
            let data = buffer.floatChannelData![0]
            for sample in 0..<Int(self.frameLength) {
                data[sample] = sin(Float(sample) * 2.0 * .pi * 440.0 / Float(self.sampleRate))
            }
        }
        return buffer
    }

    func testSilenceDetectedAsInactive() {
        let detector = FVADDetector(sampleRate: Int(self.sampleRate), mode: 0)
        let buffer = makeBuffer(silence: true)
        let result = detector.process(buffer)
        XCTAssertFalse(result, "Silence should not be detected as voice activity")
    }

    func testToneDetectedAsActive() {
        let detector = FVADDetector(sampleRate: Int(self.sampleRate), mode: 0)
        let buffer = makeBuffer(silence: false)
        let result = detector.process(buffer)
        XCTAssertTrue(result, "A 440Hz tone should be detected as voice activity")
    }

    func testHigherAggressivenessAcceptsSilence() {
        // Mode 3 (very aggressive) is more restrictive about what counts as speech.
        let detector = FVADDetector(sampleRate: Int(self.sampleRate), mode: 3)
        let buffer = makeBuffer(silence: true)
        let result = detector.process(buffer)
        XCTAssertFalse(result)
    }
}
