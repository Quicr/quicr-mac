// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import XCTest

final class TestVideoVADTransition: XCTestCase {

    // MARK: - No change

    func testNoChangeFromSpeechEnd() {
        var vad = VideoVADTransition()
        let result = vad.update(.speechEnd)
        XCTAssertEqual(result.value, .speechEnd)
        XCTAssertFalse(result.rollGroup)
        XCTAssertFalse(result.rollSubgroup)
    }

    func testNoChangeFromContinuous() {
        var vad = VideoVADTransition()
        // Rise to continuous first.
        _ = vad.update(.speechStart)
        _ = vad.update(.continuousSpeech)
        let result = vad.update(.continuousSpeech)
        XCTAssertEqual(result.value, .continuousSpeech)
        XCTAssertFalse(result.rollGroup)
        XCTAssertFalse(result.rollSubgroup)
    }

    // MARK: - Upward transitions (rollGroup = keyframe)
    // Only speechEnd → speechStart is a raw value rise (0→2).
    // That's the "I just started talking" moment — keyframe needed.

    func testRiseToSpeechStartRollsGroup() {
        var vad = VideoVADTransition()
        let result = vad.update(.speechStart)
        XCTAssertEqual(result.value, .speechStart)
        XCTAssertTrue(result.rollGroup)
        XCTAssertFalse(result.rollSubgroup)
    }

    // MARK: - Downward transitions (rollSubgroup)
    // speechStart(2) → continuousSpeech(1) is a raw value drop.
    // We already sent a keyframe on speechStart, no need for another.

    func testSpeechStartToContinuousRollsSubgroup() {
        var vad = VideoVADTransition()
        _ = vad.update(.speechStart)
        let result = vad.update(.continuousSpeech)
        XCTAssertEqual(result.value, .continuousSpeech)
        XCTAssertFalse(result.rollGroup)
        XCTAssertTrue(result.rollSubgroup)
    }

    func testDropFromSpeechStartRollsSubgroup() {
        var vad = VideoVADTransition()
        _ = vad.update(.speechStart)
        let result = vad.update(.speechEnd)
        XCTAssertEqual(result.value, .speechEnd)
        XCTAssertFalse(result.rollGroup)
        XCTAssertTrue(result.rollSubgroup)
    }

    func testDropFromContinuousRollsSubgroup() {
        var vad = VideoVADTransition()
        _ = vad.update(.speechStart)
        _ = vad.update(.continuousSpeech)
        let result = vad.update(.speechEnd)
        XCTAssertEqual(result.value, .speechEnd)
        XCTAssertFalse(result.rollGroup)
        XCTAssertTrue(result.rollSubgroup)
    }

    // MARK: - Repeated transitions

    func testRepeatedSameValueNoRolls() {
        var vad = VideoVADTransition()
        _ = vad.update(.speechStart) // initial rise
        // Repeated same value should not roll anything.
        let result = vad.update(.speechStart)
        XCTAssertEqual(result.value, .speechStart)
        XCTAssertFalse(result.rollGroup)
        XCTAssertFalse(result.rollSubgroup)
    }

    func testFullCycle() {
        var vad = VideoVADTransition()
        // Start talking — keyframe.
        let r1 = vad.update(.speechStart)
        XCTAssertTrue(r1.rollGroup)
        // Settle into continuous — raw value drops (2→1), subgroup only.
        let r2 = vad.update(.continuousSpeech)
        XCTAssertTrue(r2.rollSubgroup)
        XCTAssertFalse(r2.rollGroup)
        // Stop talking.
        let r3 = vad.update(.speechEnd)
        XCTAssertTrue(r3.rollSubgroup)
        // Stay silent.
        let r4 = vad.update(.speechEnd)
        XCTAssertFalse(r4.rollGroup)
        XCTAssertFalse(r4.rollSubgroup)
        // Start talking again — keyframe.
        let r5 = vad.update(.speechStart)
        XCTAssertTrue(r5.rollGroup)
    }
}
